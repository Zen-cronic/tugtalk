// A minimal WebSocket server side (RFC 6455) for the local server's live voice route, so local runs and the stub server
// speak the same protocol as the hosted adapter. Text and binary messages, ping/pong and close; no extensions, no
// fragmented sends. Frames from the client must be masked, as the RFC requires. Messages over maxMessage close the socket.
import { createHash } from 'node:crypto';

const GUID = '258EAFA5-E914-47DA-95CA-C5AB0DC85B11';

function frame(opcode, payload) {
  const length = payload.length;
  const head = length < 126 ? Buffer.from([0x80 | opcode, length])
    : length < 65536 ? Buffer.from([0x80 | opcode, 126, length >> 8, length & 255])
      : Buffer.concat([Buffer.from([0x80 | opcode, 127]), (() => { const b = Buffer.alloc(8); b.writeBigUInt64BE(BigInt(length)); return b; })()]);
  return Buffer.concat([head, payload]);
}

// Completes the upgrade and returns { onMessage, onClose, sendText, sendBinary, close }; null if the request is not a
// WebSocket upgrade (the socket is then answered 400).
export function acceptWebSocket(req, socket, { maxMessage = 1024 * 1024 } = {}) {
  const key = req.headers['sec-websocket-key'];
  if ((req.headers.upgrade ?? '').toLowerCase() !== 'websocket' || !key) { socket.end('HTTP/1.1 400 Bad Request\r\n\r\n'); return null; }
  const accept = createHash('sha1').update(key + GUID).digest('base64');
  socket.write(`HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: ${accept}\r\n\r\n`);
  socket.setNoDelay(true);
  let buffer = Buffer.alloc(0), parts = [], partOpcode = 0, closed = false;
  const ws = {
    onMessage: () => {}, onClose: () => {},
    sendText(text) { if (!closed) socket.write(frame(1, Buffer.from(text))); },
    sendBinary(data) { if (!closed) socket.write(frame(2, Buffer.from(data))); },
    close(code = 1000) {
      if (closed) return;
      closed = true;
      const body = Buffer.alloc(2); body.writeUInt16BE(code);
      socket.end(frame(8, body));
      ws.onClose(code);
    }
  };
  socket.on('data', chunk => {
    buffer = Buffer.concat([buffer, chunk]);
    while (buffer.length >= 2) {
      const fin = buffer[0] & 0x80, opcode = buffer[0] & 0x0f, masked = buffer[1] & 0x80;
      let length = buffer[1] & 0x7f, offset = 2;
      if (length === 126) { if (buffer.length < 4) return; length = buffer.readUInt16BE(2); offset = 4; }
      else if (length === 127) { if (buffer.length < 10) return; length = Number(buffer.readBigUInt64BE(2)); offset = 10; }
      if (!masked || length > maxMessage) return ws.close(1009);
      if (buffer.length < offset + 4 + length) return;
      const mask = buffer.subarray(offset, offset + 4);
      const payload = Buffer.from(buffer.subarray(offset + 4, offset + 4 + length));
      for (let i = 0; i < payload.length; i++) payload[i] ^= mask[i & 3];
      buffer = buffer.subarray(offset + 4 + length);
      if (opcode === 8) { ws.close(payload.length >= 2 ? payload.readUInt16BE(0) : 1000); return; }
      if (opcode === 9) { socket.write(frame(10, payload)); continue; }
      if (opcode === 10) continue;
      if (opcode !== 0) { partOpcode = opcode; parts = []; }
      parts.push(payload);
      if (!fin) continue;
      const message = Buffer.concat(parts); parts = [];
      ws.onMessage(partOpcode === 1 ? message.toString('utf8') : message);
    }
  });
  socket.on('close', () => { if (!closed) { closed = true; ws.onClose(1006); } });
  socket.on('error', () => {});
  return ws;
}

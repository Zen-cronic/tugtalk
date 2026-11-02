"""Meta MMS-TTS on Modal, as its own app (comms-coach-tts), separate from the synthetic-coaching-connector web app,
so deploying it never redeploys the main backend.

Models: facebook/mms-tts-eng and facebook/mms-tts-fra (VITS), licensed CC-BY-NC-4.0: non-commercial use, with
attribution. CPU only. The endpoint takes a shared secret (Modal secret comms-coach-tts-auth, key MMS_TTS_TOKEN);
the main backend gets the same value as MMS_TTS_TOKEN, plus MMS_TTS_URL and SPEECH_PROVIDER=mms.

Deploy (a gate; see the build checkpoint): modal deploy deploy/mms_tts_app.py --profile meta-connector --env main
"""
from pathlib import Path
import modal

ROOT = Path(__file__).resolve().parent
MODELS = {'en': 'facebook/mms-tts-eng', 'fr': 'facebook/mms-tts-fra'}


def download():
    from transformers import VitsModel, AutoTokenizer
    for name in MODELS.values():
        VitsModel.from_pretrained(name); AutoTokenizer.from_pretrained(name)


image = (modal.Image.debian_slim(python_version='3.12')
         .pip_install('torch==2.5.1', index_url='https://download.pytorch.org/whl/cpu')
         .pip_install('transformers==4.46.3', 'numpy<3')
         # Weights are baked into the image, so a cold start does not download them.
         .run_function(download)
         .add_local_file(ROOT / 'tts_asgi.py', '/app/tts_asgi.py'))
app = modal.App('comms-coach-tts')
auth = modal.Secret.from_name('comms-coach-tts-auth')


@app.cls(image=image, secrets=[auth], cpu=2.0, memory=2048, min_containers=0, max_containers=1, scaledown_window=300, timeout=60)
@modal.concurrent(max_inputs=2)
class Voice:
    @modal.enter()
    def load(self):
        import torch
        from transformers import VitsModel, AutoTokenizer
        torch.set_num_threads(2)
        self.torch = torch
        self.models = {lang: (VitsModel.from_pretrained(name).eval(), AutoTokenizer.from_pretrained(name)) for lang, name in MODELS.items()}

    def synthesize(self, text, language):
        model, tokenizer = self.models[language]
        with self.torch.inference_mode():
            waveform = model(**tokenizer(text, return_tensors='pt')).waveform[0]
        return waveform.tolist(), model.config.sampling_rate

    @modal.asgi_app()
    def web(self):
        import os, sys
        sys.path.insert(0, '/app')
        from tts_asgi import create_tts_app
        return create_tts_app(self.synthesize, os.environ['MMS_TTS_TOKEN'])

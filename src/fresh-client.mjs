// Stateless app-side reader: every invocation fetches anew, with no stale fallback.
export function createFreshReader({baseUrl,token,fetchImpl=fetch}) {
  async function read(path) {
    const response=await fetchImpl(new URL(path,baseUrl),{cache:'no-store',headers:{Authorization:`Bearer ${token}`,'Cache-Control':'no-cache'}});
    if(!response.ok) throw new Error(`Current goal state unavailable (HTTP ${response.status})`);
    const data=await response.json();
    const age=Date.now()-Date.parse(data.as_of);
    if(!Number.isFinite(age)||age>30000||age< -30000||!data.snapshot_revision||!data.request_id||data.request_id!==response.headers.get('x-request-id'))
      throw new Error('Current goal state unavailable: missing or stale retrieval metadata');
    return data;
  }
  return {overview:()=>read('/v1/overview'),goal:id=>read(`/v1/goals/${encodeURIComponent(id)}/context`)};
}

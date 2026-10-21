import type { Action } from '../../contracts/src/index.ts';
import { ensure } from '../../policy/src/index.ts';
export class GitHubConnector {
  constructor(private token:string,private request:typeof fetch=fetch){}
  private async call(path:string,init:RequestInit={}){
    const response=await this.request(`https://api.github.com${path}`,{...init,headers:{Accept:'application/vnd.github+json','X-GitHub-Api-Version':'2022-11-28',Authorization:`Bearer ${this.token}`,...init.headers},signal:AbortSignal.timeout(15000),redirect:'error'});
    ensure(response.ok,'github_request_failed',`GitHub HTTP ${response.status}`);return response.json() as Promise<Record<string,unknown>>;
  }
  marker(action:Action){return `<!-- neuraos:${action.idempotencyKey} -->`;}
  async createIssue(action:Action){
    ensure(action.kind==='github.issue.create','unsupported_action');
    const created=await this.call(`/repos/${action.target}/issues`,{method:'POST',body:JSON.stringify({...action.payload,body:action.payload.body+'\n\n'+this.marker(action)})});
    const id=String(created.number);return this.verify(action,id);
  }
  async verify(action:Action,id:string){
    ensure(/^\d+$/.test(id),'invalid_external_id');
    const item=await this.call(`/repos/${action.target}/issues/${id}`);
    ensure(item.title===action.payload.title&&item.body===action.payload.body+'\n\n'+this.marker(action),'external_content_mismatch');
    ensure(typeof item.html_url==='string'&&item.html_url.startsWith(`https://github.com/${action.target}/issues/`),'external_url_mismatch');
    return {externalId:id,resultUrl:item.html_url};
  }
}

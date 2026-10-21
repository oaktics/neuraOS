/** Provider usage counts input, output and cached input; cached tokens are not free tokens. */
export class TokenMeter {
 tokens=0;measured=false;private input=0;private output=0;private pending='';private decoder=new TextDecoder();
 constructor(private provider:'codex'|'claude'){}
 observe(message:any){
  if(this.provider==='codex'){
   const usage=message.response?.usage??message.usage;if(usage&&typeof usage.total_tokens==='number'){this.tokens=Math.max(this.tokens,usage.total_tokens);this.measured=true;}
  }else{
   const usage=message.message?.usage??message.usage;if(!usage)return;
   if(typeof usage.input_tokens==='number'){this.input=Math.max(this.input,usage.input_tokens+(usage.cache_creation_input_tokens??0)+(usage.cache_read_input_tokens??0));this.measured=true;}
   this.output=Math.max(this.output,usage.output_tokens??0);this.tokens=this.input+this.output;
  }
 }
 feed(bytes:Uint8Array){this.pending+=this.decoder.decode(bytes,{stream:true});let at:number;
  while((at=this.pending.indexOf('\n'))>=0){const line=this.pending.slice(0,at).trim();this.pending=this.pending.slice(at+1);if(line.startsWith('data:'))try{this.observe(JSON.parse(line.slice(5).trim()));}catch{}}
  if(this.pending.length>8*1024*1024)this.pending='';
 }
}

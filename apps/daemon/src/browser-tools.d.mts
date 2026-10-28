export const browserTools: Array<{name:string;description:string;inputSchema:Record<string,unknown>}>;
export function callBrowser(name:string,args:Record<string,unknown>,request:(path:string,body:unknown,headers?:Record<string,string>)=>Promise<any>,terminalId:string,credential:string):Promise<{content:Array<{type:string;text?:string;mimeType?:string;data?:string}>}>;

import { mkdir, writeFile, readFile } from 'node:fs/promises';
import { join } from 'node:path';
import { contentHash, ensure } from '../../policy/src/index.ts';
import { S3Client,PutObjectCommand,GetObjectCommand } from '@aws-sdk/client-s3';
export interface BlobStore {put(key:string,data:string):Promise<void>;get(key:string):Promise<string>}
function validKey(key:string){ensure(/^[a-zA-Z0-9/_-]+$/.test(key)&&!key.includes('..'),'invalid_storage_key');}
export class FileBlobStore implements BlobStore {
  constructor(private root:string){}
  async put(key:string,data:string){validKey(key);const path=join(this.root,key);await mkdir(join(path,'..'),{recursive:true,mode:0o700});try{await writeFile(path,data,{flag:'wx',mode:0o600});}catch(e){if((e as NodeJS.ErrnoException).code!=='EEXIST')throw e;ensure(contentHash(await readFile(path))===contentHash(data),'immutable_blob_conflict');}}
  async get(key:string){validKey(key);return readFile(join(this.root,key),'utf8');}
}
export class S3BlobStore implements BlobStore {
  private client:S3Client;
  constructor(endpoint:string,private bucket:string,accessKeyId:string,secretAccessKey:string){ensure(endpoint.startsWith('https://'),'storage_tls_required');this.client=new S3Client({endpoint,region:'auto',credentials:{accessKeyId,secretAccessKey},requestChecksumCalculation:'WHEN_REQUIRED',responseChecksumValidation:'WHEN_REQUIRED'});}
  async put(key:string,data:string){validKey(key);try{await this.client.send(new PutObjectCommand({Bucket:this.bucket,Key:key,Body:data,ContentType:'application/octet-stream',IfNoneMatch:'*'}),{abortSignal:AbortSignal.timeout(30000)});}catch(error){if((error as {$metadata?:{httpStatusCode?:number}}).$metadata?.httpStatusCode!==412)throw error;ensure(contentHash(await this.get(key))===contentHash(data),'immutable_blob_conflict');}}
  async get(key:string){validKey(key);const r=await this.client.send(new GetObjectCommand({Bucket:this.bucket,Key:key}),{abortSignal:AbortSignal.timeout(30000)});ensure(r.Body,'storage_read_failed');return r.Body.transformToString();}
}

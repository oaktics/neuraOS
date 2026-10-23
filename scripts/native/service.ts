import {replaceLaunchAgent} from './launch-agent.ts';
import {homedir} from 'node:os';
import {resolve,join} from 'node:path';
import {mkdir,writeFile} from 'node:fs/promises';
import {execFile} from 'node:child_process';
import {promisify} from 'node:util';
const exec=promisify(execFile),action=process.argv[2]??'status',id='app.neuraos.daemon',domain=`gui/${process.getuid!()}`;
const root=resolve(import.meta.dirname,'../..');
if(process.platform!=='darwin')throw new Error('LaunchAgent is macOS-only');
const data=join(homedir(),'Library/Application Support/neuraOS/Developer'),plist=join(homedir(),'Library/LaunchAgents',id+'.plist');
if(action==='install'){
  await mkdir(data,{recursive:true,mode:0o700});await mkdir(join(homedir(),'Library/LaunchAgents'),{recursive:true});
  const escape=(x:string)=>x.replaceAll('&','&amp;').replaceAll('<','&lt;').replaceAll('>','&gt;').replaceAll('"','&quot;');
  const args=[process.execPath,'--import',join(root,'node_modules/tsx/dist/loader.mjs'),join(root,'apps/daemon/src/main.ts')];
  const xml=`<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>Label</key><string>${id}</string><key>ProgramArguments</key><array>${args.map(x=>`<string>${escape(x)}</string>`).join('')}</array><key>WorkingDirectory</key><string>${escape(root)}</string><key>EnvironmentVariables</key><dict><key>NEURA_DEV_DATA_DIR</key><string>${escape(data)}</string><key>PATH</key><string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string></dict><key>RunAtLoad</key><true/><key>KeepAlive</key><true/><key>ThrottleInterval</key><integer>10</integer><key>StandardOutPath</key><string>${escape(join(data,'daemon.log'))}</string><key>StandardErrorPath</key><string>${escape(join(data,'daemon-error.log'))}</string></dict></plist>`;
  await writeFile(plist,xml,{mode:0o600});await exec('plutil',['-lint',plist]);
  await replaceLaunchAgent(domain,id,plist);console.log('neuraOS Daemon installed.');
} else if(action==='stop') {await exec('launchctl',['bootout',`${domain}/${id}`]);console.log('Daemon stopped.');}
else if(action==='restart') {await exec('launchctl',['kickstart','-k',`${domain}/${id}`]);console.log('Daemon restarted.');}
else {console.log((await exec('launchctl',['print',`${domain}/${id}`])).stdout);}

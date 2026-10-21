import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';
import tailwindcss from '@tailwindcss/vite';
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
export default defineConfig({
  root:resolve(import.meta.dirname),plugins:[react(),tailwindcss()],clearScreen:false,
  server:{host:'127.0.0.1',port:1420,strictPort:true,proxy:{'/api':{
    target:`http://127.0.0.1:${process.env.NEURA_RUNNER_PORT??4317}`,
    configure(proxy){proxy.on('proxyReq',(req)=>{try{req.setHeader('Authorization','Bearer '+readFileSync(resolve(process.env.NEURA_DATA_DIR??'.data','runner-token'),'utf8').trim());}catch{}});}
  }}},build:{outDir:'dist',emptyOutDir:true}
});

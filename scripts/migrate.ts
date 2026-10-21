import pg from 'pg';
import { readFile } from 'node:fs/promises';
if(!process.env.DATABASE_URL)throw new Error('DATABASE_URL required (migration role)');
const pool=new pg.Pool({connectionString:process.env.DATABASE_URL});try{await pool.query(await readFile('database/migrations/001_core.sql','utf8'));process.stdout.write('Migration 001 applied. Configure a non-bypass runtime role before starting Cloud API.\n');}finally{await pool.end();}

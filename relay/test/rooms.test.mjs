import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync,readFileSync,rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import {setTimeout as delay} from 'node:timers/promises';
import {randomUUID} from 'node:crypto';
import WebSocket from 'ws';
import {createRelay} from '../server.mjs';
async function peer(url,action,fields={}) {
 const ws=new WebSocket(url), queue=[], waiting=[];
 ws.on('error',()=>{}); ws.on('message',bytes=>{const packet=JSON.parse(bytes); const index=waiting.findIndex(w=>w.type===packet.type); if(index<0)queue.push(packet);else {const [w]=waiting.splice(index,1);clearTimeout(w.timer);w.resolve(packet);}});
 await new Promise((resolve,reject)=>{ws.once('open',resolve);ws.once('error',reject);});
 const next=type=>{const index=queue.findIndex(p=>p.type===type);if(index>=0)return Promise.resolve(queue.splice(index,1)[0]);return new Promise((resolve,reject)=>{const w={type,resolve,timer:setTimeout(()=>reject(new Error('Room timeout: '+type)),2000)};waiting.push(w);});};
 ws.send(JSON.stringify({type:'hello',version:1,action,name:'会话验证',...fields}));
 return {ws,next,send:p=>ws.send(JSON.stringify(p)),welcome:await next(action==='bad'?'error':'welcome'),close:()=>new Promise(resolve=>{ws.once('close',resolve);ws.close();})};
}
test('room, identity and original credential survive a full server restart without storing plain tokens',async t=>{
 const dir=mkdtempSync(join(tmpdir(),'lolping-rooms-'));
 let relay=createRelay({sessionDirectory:dir});t.after(async()=>{await relay.close();rmSync(dir,{recursive:true,force:true});});let addr=await relay.listen(0);
 const url=`ws://127.0.0.1:${addr.port}/ws`, a=await peer(url,'create'), b=await peer(url,'join',{room:a.welcome.room});
 const savedA=a.welcome,savedB=b.welcome; assert.ok(savedA.capabilities.includes('persistent-session-v1'));
 await relay.close();
 const serialized=readFileSync(join(dir,'rooms.json'),'utf8');assert.equal(serialized.includes(savedA.token),false);assert.equal(serialized.includes(savedB.token),false);
 relay=createRelay({sessionDirectory:dir});addr=await relay.listen(0);
 const newUrl=`ws://127.0.0.1:${addr.port}/ws`;
 const resumedA=await peer(newUrl,'resume',{room:savedA.room,token:savedA.token});
 const resumedB=await peer(newUrl,'resume',{room:savedB.room,token:savedB.token});
 assert.equal(resumedA.welcome.memberID,savedA.memberID);assert.equal(resumedB.welcome.memberID,savedB.memberID);assert.equal(resumedA.welcome.room,savedA.room);
 resumedA.send({type:'ping',kind:'assist',eventID:randomUUID(),position:{nx:0.2,ny:0.7}});assert.deepEqual((await resumedB.next('ping')).position,{nx:0.2,ny:0.7});
 resumedA.send({type:'leave'});await delay(30);
 const replacement=await peer(newUrl,'join',{room:savedA.room});assert.notEqual(replacement.welcome.memberID,savedA.memberID);
});
test('persistent offline retention is distinct from the old short reconnect grace period',async t=>{
 const dir=mkdtempSync(join(tmpdir(),'lolping-rooms-retention-'));
 const relay=createRelay({sessionDirectory:dir,graceMs:20,roomRetentionMs:1000});t.after(async()=>{await relay.close();rmSync(dir,{recursive:true,force:true});});const addr=await relay.listen(0);
 const url=`ws://127.0.0.1:${addr.port}/ws`,a=await peer(url,'create');await a.close();await delay(80);
 const resumed=await peer(url,'resume',{room:a.welcome.room,token:a.welcome.token});assert.equal(resumed.welcome.room,a.welcome.room);
 resumed.send({type:'leave'});await delay(30);assert.equal(JSON.parse(readFileSync(join(dir,'rooms.json'))).rooms.length,0);
});

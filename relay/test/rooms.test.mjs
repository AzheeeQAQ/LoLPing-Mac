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
const SHARED=['emote-png-v1','relative-position-v1','shared-counter-v1'];
const op=(delta)=>({type:'counter_op',eventID:randomUUID(),delta});
test('shared room counter: personal counts merge once, every click reaches both, never below zero',async t=>{
 let now=Date.parse('2026-11-16T03:00:00Z'); // UTC+8 2026-11-16 11:00
 const relay=createRelay({clock:()=>now});t.after(()=>relay.close());const addr=await relay.listen(0);
 const url=`ws://127.0.0.1:${addr.port}/ws`;
 const a=await peer(url,'create',{name:'甲',capabilities:SHARED,counterSeed:{day:'2026-11-16',today:1,total:6}});
 assert.ok(a.welcome.capabilities.includes('shared-counter-v1'));
 assert.deepEqual(a.welcome.roomCounter,{day:'2026-11-16',today:1,total:6});
 // B's count from yesterday adds to the total only.
 const b=await peer(url,'join',{room:a.welcome.room,name:'乙',capabilities:SHARED,counterSeed:{day:'2026-11-15',today:4,total:10}});
 assert.deepEqual(b.welcome.roomCounter,{day:'2026-11-16',today:1,total:16});
 const merged=await a.next('room_counter');assert.deepEqual(merged,{type:'room_counter',counter:{day:'2026-11-16',today:1,total:16}});
 const sent=op(1);b.send(sent);
 for(const p of [a,b]){const m=await p.next('room_counter');assert.deepEqual(m.counter,{day:'2026-11-16',today:2,total:17});
  assert.equal(m.delta,1);assert.equal(m.eventID,sent.eventID.toLowerCase());assert.deepEqual(m.sender,{id:b.welcome.memberID,name:'乙'});}
 b.send(sent);await delay(50); // a duplicate event is ignored
 a.send(op(-5));for(const p of [a,b]){const m=await p.next('room_counter');assert.equal(m.delta,-2);assert.deepEqual(m.counter,{day:'2026-11-16',today:0,total:15});}
 a.send(op(-1));for(const p of [a,b]){const m=await p.next('room_counter');assert.equal(m.delta,0);assert.equal(m.counter.total,15);}
 // Reconnecting with a seed again never re-adds it.
 const again=await peer(url,'resume',{room:a.welcome.room,token:a.welcome.token,capabilities:SHARED,counterSeed:{day:'2026-11-16',today:9,total:99}});
 assert.deepEqual(again.welcome.roomCounter,{day:'2026-11-16',today:0,total:15});
 // UTC+8 midnight: today resets, total stays.
 again.send(op(3));await again.next('room_counter');
 now=Date.parse('2026-11-16T16:00:00Z');
 again.send(op(1));const rolled=await again.next('room_counter');assert.deepEqual(rolled.counter,{day:'2026-11-17',today:1,total:19});
});
test('shared counter is invisible to 1.9.x/1.10.0 clients and validated',async t=>{
 const relay=createRelay();t.after(()=>relay.close());const addr=await relay.listen(0);
 const url=`ws://127.0.0.1:${addr.port}/ws`;
 const a=await peer(url,'create',{capabilities:SHARED});
 const old=await peer(url,'join',{room:a.welcome.room,capabilities:['emote-png-v1','relative-position-v1','daily-counter-v1']});
 assert.equal(old.welcome.roomCounter,undefined);
 a.send(op(1));await a.next('room_counter');
 a.send({type:'ping',kind:'push',eventID:randomUUID(),position:{nx:0.5,ny:0.5}});assert.equal((await old.next('ping')).kind,'push');
 const stray=[];old.ws.on('message',d=>{const m=JSON.parse(d);if(m.type==='room_counter')stray.push(m);});await delay(50);assert.equal(stray.length,0);
 old.send(op(1));assert.equal((await old.next('error')).code,'invalid_counter');
 for(const bad of [{type:'counter_op',eventID:randomUUID(),delta:0},{type:'counter_op',eventID:randomUUID(),delta:21},{type:'counter_op',eventID:randomUUID(),delta:1.5},{type:'counter_op',eventID:'x',delta:1},{type:'counter_op',eventID:randomUUID(),delta:'1'}]){
  const p=await peer(url,'create',{capabilities:SHARED});p.send(bad);assert.equal((await p.next('error')).code,'invalid_counter');}
 const badSeed=new WebSocket(url);await new Promise(r=>badSeed.once('open',r));
 const got=new Promise(r=>badSeed.once('message',d=>r(JSON.parse(d))));
 badSeed.send(JSON.stringify({type:'hello',version:1,action:'create',name:'坏种子',capabilities:SHARED,counterSeed:{day:'2026-11-16',today:5,total:1}}));
 assert.equal((await got).code,'invalid_counter');
});
test('shared room counter and seeding survive a restart',async t=>{
 const dir=mkdtempSync(join(tmpdir(),'lolping-rooms-counter-'));
 let relay=createRelay({sessionDirectory:dir});t.after(async()=>{await relay.close();rmSync(dir,{recursive:true,force:true});});let addr=await relay.listen(0);
 const url=`ws://127.0.0.1:${addr.port}/ws`;const day=new Date(Date.now()+8*3600e3).toISOString().slice(0,10);
 const a=await peer(url,'create',{capabilities:SHARED,counterSeed:{day,today:2,total:7}});
 a.send(op(3));await a.next('room_counter');
 await relay.close();
 const saved=JSON.parse(readFileSync(join(dir,'rooms.json'),'utf8'));
 assert.deepEqual(saved.rooms[0].counter,{day,today:5,total:10});assert.equal(saved.rooms[0].members[0].counterSeeded,true);
 relay=createRelay({sessionDirectory:dir});addr=await relay.listen(0);
 const back=await peer(`ws://127.0.0.1:${addr.port}/ws`,'resume',{room:a.welcome.room,token:a.welcome.token,capabilities:SHARED,counterSeed:{day,today:2,total:7}});
 assert.deepEqual(back.welcome.roomCounter,{day,today:5,total:10});
 back.send({type:'leave'});await delay(30);
});

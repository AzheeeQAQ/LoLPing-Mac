import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, rmSync, readFileSync, existsSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { randomUUID, createHash, randomBytes } from 'node:crypto';
import { deflateSync } from 'node:zlib';
import WebSocket from 'ws';
import { createRelay } from '../server.mjs';
function png(index) {
  function crc(data) { let c=0xffffffff; for (const b of data) { c ^= b; for (let i=0;i<8;i++) c=(c>>>1)^((c&1)?0xedb88320:0); } return (c^0xffffffff)>>>0; }
  function chunk(type,data) { const body=Buffer.concat([Buffer.from(type),data]), length=Buffer.alloc(4), sum=Buffer.alloc(4); length.writeUInt32BE(data.length); sum.writeUInt32BE(crc(body)); return Buffer.concat([length,body,sum]); }
  const header=Buffer.alloc(13); header.writeUInt32BE(1,0); header.writeUInt32BE(1,4); header[8]=8; header[9]=6;
  return Buffer.concat([Buffer.from([137,80,78,71,13,10,26,10]),chunk('IHDR',header),chunk('IDAT',deflateSync(Buffer.from([0,index%256,Math.floor(index/256),128,255]))),chunk('IEND',Buffer.alloc(0))]);
}
function image(index=1) { const bytes=png(index); return { id:createHash('sha256').update(bytes).digest('hex'),name:'图片'+index,png:bytes.toString('base64') }; }
const token=()=>randomBytes(32).toString('hex');
async function rpc(url,type,fields={}) {
  const ws=new WebSocket(url), requestID=randomUUID();
  return new Promise((resolve,reject)=> {
    const timer=setTimeout(()=>{ws.terminate();reject(new Error('gallery timeout'));},2500);
    ws.on('error',reject); ws.on('open',()=>ws.send(JSON.stringify({type,requestID,...fields})));
    ws.on('message',data=>{ clearTimeout(timer); const reply=JSON.parse(data.toString()); ws.close(); assert.equal(reply.type,'gallery_result'); assert.equal(reply.requestID,requestID); resolve(reply); });
  });
}
async function fixture(t,options={}) {
  const directory=mkdtempSync(join(tmpdir(),'lolping-gallery-')); t.after(()=>rmSync(directory,{recursive:true,force:true}));
  const relay=createRelay({galleryDirectory:directory,...options}); const address=await relay.listen(0); t.after(()=>relay.close());
  return {directory,relay,url:`ws://127.0.0.1:${address.port}/ws`};
}
test('public upload/list/download persist across a real relay restart without joining rooms',async t=>{
  const directory=mkdtempSync(join(tmpdir(),'lolping-gallery-restart-')); t.after(()=>rmSync(directory,{recursive:true,force:true}));
  let relay=createRelay({galleryDirectory:directory}), address=await relay.listen(0);
  const url=`ws://127.0.0.1:${address.port}/ws`, emote=image(), ownerToken=token();
  const upload=await rpc(url,'gallery_upload',{emote,uploader:'分享者',ownerToken});
  assert.equal(upload.owned,true); assert.equal(upload.item.id,emote.id);
  const list=await rpc(url,'gallery_list'); assert.equal(list.items.length,1); assert.equal(list.items[0].uploader,'分享者');
  assert.equal(JSON.stringify(list).includes(ownerToken),false); assert.equal(JSON.stringify(list).includes('ownerHash'),false);
  assert.deepEqual((await rpc(url,'gallery_get',{id:emote.id})).emote,emote);
  await relay.close(); relay=createRelay({galleryDirectory:directory}); address=await relay.listen(0); t.after(()=>relay.close());
  const restarted=`ws://127.0.0.1:${address.port}/ws`;
  assert.equal((await rpc(restarted,'gallery_list')).total,1);
  assert.deepEqual((await rpc(restarted,'gallery_get',{id:emote.id})).emote,emote);
  assert.equal((await rpc(restarted,'gallery_delete',{id:emote.id,ownerToken})).id,emote.id);
  assert.equal((await rpc(restarted,'gallery_list')).total,0); assert.equal(existsSync(join(directory,emote.id+'.png')),false);
});
test('duplicate uploads cannot replace metadata, reclaim ownership or delete someone else',async t=>{
  const {url,directory}=await fixture(t), emote=image(2), ownerToken=token();
  await rpc(url,'gallery_upload',{emote,uploader:'原作者',ownerToken});
  const same=await rpc(url,'gallery_upload',{emote,uploader:'重试',ownerToken}); assert.equal(same.owned,true); assert.equal(same.duplicate,true);
  const other=await rpc(url,'gallery_upload',{emote:{...emote,name:'冒充'},uploader:'其他人',ownerToken:token()});
  assert.equal(other.owned,false); assert.equal(other.item.name,emote.name); assert.equal(other.item.uploader,'原作者'); assert.equal(other.ownerToken,undefined);
  assert.equal((await rpc(url,'gallery_delete',{id:emote.id,ownerToken:token()})).code,'not_owner');
  assert.equal((await rpc(url,'gallery_delete',{id:'../index.json',ownerToken})).code,'not_owner');
  const stored=readFileSync(join(directory,'index.json'),'utf8'); assert.equal(stored.includes(ownerToken),false);
  assert.equal((await rpc(url,'gallery_list')).total,1);
});
test('PNG hash/size, names, quota, upload rate and malformed cursor are bounded',async t=>{
  const {url}=await fixture(t,{maxGalleryItems:1,galleryUploadsPerMinute:5});
  const ownerToken=token(), emote=image(3);
  assert.equal((await rpc(url,'gallery_upload',{emote:{...emote,id:'0'.repeat(64)},uploader:'甲',ownerToken})).code,'invalid_emote');
  assert.equal((await rpc(url,'gallery_upload',{emote,uploader:'\n',ownerToken})).code,'invalid_name');
  assert.equal((await rpc(url,'gallery_upload',{emote,uploader:'甲',ownerToken})).owned,true);
  assert.equal((await rpc(url,'gallery_upload',{emote:image(4),uploader:'乙',ownerToken:token()})).code,'gallery_full');
  assert.equal((await rpc(url,'gallery_get',{id:'../file'})).code,'invalid_asset');
  assert.equal((await rpc(url,'gallery_list',{cursor:-1})).code,'invalid_cursor');
  const limited=await fixture(t,{galleryUploadsPerMinute:1});
  await rpc(limited.url,'gallery_upload',{emote,uploader:'甲',ownerToken});
  assert.equal((await rpc(limited.url,'gallery_upload',{emote:image(5),uploader:'甲',ownerToken:token()})).code,'rate_limited');
});
test('public list paginates without disclosing credentials or image blobs',async t=>{
  const {url}=await fixture(t,{galleryUploadsPerMinute:100});
  for(let i=0;i<53;i++) await rpc(url,'gallery_upload',{emote:image(100+i),uploader:'测试',ownerToken:token()});
  const first=await rpc(url,'gallery_list'), second=await rpc(url,'gallery_list',{cursor:first.nextCursor});
  assert.equal(first.items.length,50); assert.equal(second.items.length,3); assert.equal(second.nextCursor,null);
  assert.equal(new Set([...first.items,...second.items].map(x=>x.id)).size,53);
  for(const item of [...first.items,...second.items]) assert.deepEqual(Object.keys(item).sort(),['createdAt','id','name','uploader']);
});
test('old server configuration returns a clear disabled response',async t=>{
  const relay=createRelay(); const address=await relay.listen(0); t.after(()=>relay.close());
  const result=await rpc(`ws://127.0.0.1:${address.port}/ws`,'gallery_list'); assert.equal(result.code,'gallery_disabled');
});

test('public names normalize whitespace, combining forms and hidden control characters',async t=>{
  const {url}=await fixture(t), emote={...image(700),name:' cafe\u0301\u0085 '};
  const reply=await rpc(url,'gallery_upload',{emote,uploader:'\u200b朋友 ',ownerToken:token()});
  assert.equal(reply.item.name,'café'); assert.equal(reply.item.uploader,'朋友');
  const list=await rpc(url,'gallery_list'); assert.equal(list.items[0].name,'café');
  assert.equal((await rpc(url,'gallery_get',{id:emote.id})).emote.name,'café');
});

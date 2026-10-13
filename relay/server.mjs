import http from 'node:http';
import { randomBytes, randomUUID, timingSafeEqual, createHash } from 'node:crypto';
import { pathToFileURL } from 'node:url';
import { isIP } from 'node:net';
import WebSocket, { WebSocketServer } from 'ws';
import { GalleryStore, validAssetID } from './gallery.mjs';

const alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
const kinds = new Set(['retreat', 'push', 'onMyWay', 'allIn', 'assist', 'needVision', 'missing', 'enemyVision', 'generic']);
const emoteCapability = 'emote-png-v1';
const maxMessageBytes = 49_152;
function validEmote(value) {
  if (!value || typeof value !== 'object' || !/^[0-9a-f]{64}$/.test(value.id) || !validName(value.name) ||
      typeof value.png !== 'string' || value.png.length > 43_692 || !/^[A-Za-z0-9+/]+={0,2}$/.test(value.png)) return false;
  const png = Buffer.from(value.png, 'base64');
  if (png.length < 33 || png.length > 32_768 || png.toString('base64') !== value.png ||
      !png.subarray(0, 8).equals(Buffer.from([137,80,78,71,13,10,26,10])) || png.toString('ascii', 12, 16) !== 'IHDR') return false;
  const width = png.readUInt32BE(16), height = png.readUInt32BE(20);
  return width > 0 && height > 0 && width <= 160 && height <= 160 && createHash('sha256').update(png).digest('hex') === value.id;
}
const validRoom = (value) => typeof value === 'string' && /^[A-HJ-NP-Z2-9]{12}$/.test(value);
const validUUID = (value) => typeof value === 'string' && /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(value);
const validName = (value) => typeof value === 'string' && value.trim().length > 0 &&
  Array.from(value).length <= 24 && !/[\u0000-\u001f\u007f]/.test(value);

export function createRelay({ graceMs = 60_000, maxRooms = 500, maxConnections = 1000, heartbeatMs = 25_000,
  trustProxy = false, maxConnectionsPerAddress = 20, galleryDirectory = null, maxGalleryItems = 500,
  galleryUploadsPerMinute = 12 } = {}) {
  for (const value of [graceMs, maxRooms, maxConnections, heartbeatMs, maxConnectionsPerAddress, galleryUploadsPerMinute]) {
    if (!Number.isInteger(value) || value < 1) throw new Error('Relay limits must be positive integers');
  }
  const rooms = new Map();
  const gallery = galleryDirectory ? new GalleryStore(galleryDirectory, { maxItems: maxGalleryItems, validate: validEmote }) : null;
  const uploadWindows = new Map();
  const byAddress = new Map();
  const server = http.createServer((req, res) => {
    const healthy = req.url === '/health' && req.method === 'GET';
    res.writeHead(healthy ? 200 : 404, { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' });
    res.end(JSON.stringify(healthy ? { status: 'ok', protocol: 1 } : { error: 'not_found' }));
  });
  const wss = new WebSocketServer({ noServer: true, maxPayload: maxMessageBytes, perMessageDeflate: false });
  const send = (ws, packet) => {
    if (ws.readyState !== WebSocket.OPEN) return;
    if (ws.bufferedAmount > 131_072) { ws.terminate(); return; }
    ws.send(JSON.stringify(packet));
  };
  const roster = (room) => [...room.members.values()].filter((member) => member.ws?.readyState === WebSocket.OPEN)
    .map(({ id, name }) => ({ id, name }));
  const broadcastPeers = (room) => {
    const packet = { type: 'peers', peers: roster(room) };
    for (const member of room.members.values()) if (member.ws) send(member.ws, packet);
  };
  const prune = (room) => {
    for (const [id, member] of room.members) {
      if (!member.ws && Date.now() - member.disconnectedAt >= graceMs) room.members.delete(id);
    }
    if (room.members.size === 0) rooms.delete(room.code);
  };
  const reject = (ws, code, message) => {
    send(ws, { type: 'error', code, message });
    ws.close(1008, code);
  };
  const addressOf = (req) => {
    // Only enable behind a private/loopback reverse proxy which overwrites XFF.
    const forwarded = req.headers['x-forwarded-for'];
    if (trustProxy && typeof forwarded === 'string') {
      const address = forwarded.split(',').at(-1).trim();
      if (isIP(address)) return address;
    }
    return req.socket.remoteAddress;
  };
  server.on('upgrade', (req, socket, head) => {
    const address = addressOf(req);
    if (req.url !== '/ws' || wss.clients.size >= maxConnections || (byAddress.get(address) ?? 0) >= maxConnectionsPerAddress) {
      socket.end('HTTP/1.1 503 Service Unavailable\r\nConnection: close\r\n\r\n'); return;
    }
    wss.handleUpgrade(req, socket, head, (ws) => { ws.clientAddress = address; wss.emit('connection', ws, req); });
  });
  wss.on('connection', (ws, req) => {
    const address = ws.clientAddress;
    byAddress.set(address, (byAddress.get(address) ?? 0) + 1);
    let room, member, galleryOnly = false, alive = true, tokens = 12, lastRefill = Date.now(), byteTokens = 131_072, lastEmote = 0;
    const authTimer = setTimeout(() => reject(ws, 'hello_timeout', '连接超时，请重新连接。'), 8000);
    authTimer.unref();
    ws.on('error', () => {}); // Malformed/oversized frames must not crash the relay.
    ws.on('pong', () => { alive = true; });
    ws.checkAlive = () => {
      if (!alive) { ws.terminate(); return; }
      alive = false;
      if (ws.readyState === WebSocket.OPEN) ws.ping();
    };
    ws.on('message', (data, binary) => {
      if (ws.readyState !== WebSocket.OPEN) return;
      const now = Date.now();
      tokens = Math.min(12, tokens + (now-lastRefill)*0.006); lastRefill = now;
      if (tokens < 1) { send(ws, { type: 'error', code: 'rate_limited', message: '发送太快，请稍等一下。' }); return; }
      tokens -= 1;
      byteTokens = Math.min(131_072, byteTokens + (now-(ws.byteRefill ?? now))*65.536); ws.byteRefill = now;
      if (data.length > byteTokens) { send(ws, { type: 'error', code: 'rate_limited' }); return; }
      byteTokens -= data.length;
      let packet;
      try { packet = JSON.parse(data.toString()); } catch { reject(ws, 'invalid_message', '消息格式不正确。'); return; }
      if (binary || !packet || typeof packet !== 'object' || Array.isArray(packet)) {
        reject(ws, 'invalid_message', '只支持 JSON 文本消息。'); return;
      }
      if (typeof packet.type === 'string' && packet.type.startsWith('gallery_')) {
        if (!validUUID(packet.requestID)) { reject(ws, 'invalid_request', '请求编号无效。'); return; }
        if (!member) { galleryOnly = true; clearTimeout(authTimer); }
        const response = { type: 'gallery_result', requestID: packet.requestID };
        try {
          if (!gallery) throw Object.assign(new Error('服务器尚未启用公共图片库，请更新服务器。'), { code: 'gallery_disabled' });
          switch (packet.type) {
          case 'gallery_list': Object.assign(response, gallery.list(packet.cursor ?? 0)); break;
          case 'gallery_get': Object.assign(response, gallery.get(packet.id)); break;
          case 'gallery_upload': {
            if (!validName(packet.uploader)) throw Object.assign(new Error('上传昵称无效。'), { code: 'invalid_name' });
            if (!validAssetID(packet.ownerToken)) throw Object.assign(new Error('上传凭证无效。'), { code: 'not_owner' });
            let window = uploadWindows.get(address);
            if (!window || now-window.start >= 60_000) { window = { start: now, count: 0 }; uploadWindows.set(address, window); }
            if (window.count >= galleryUploadsPerMinute) throw Object.assign(new Error('上传太快，请稍后再上传。'), { code: 'rate_limited' });
            window.count += 1;
            Object.assign(response, gallery.upload(packet.emote, packet.uploader.trim(), packet.ownerToken)); break;
          }
          case 'gallery_delete': Object.assign(response, gallery.remove(packet.id, packet.ownerToken)); break;
          default: throw Object.assign(new Error('公共库请求无效。'), { code: 'invalid_request' });
          }
        } catch (error) {
          response.code = error.code && ['gallery_disabled','invalid_cursor','invalid_asset','asset_missing','invalid_emote','gallery_full','not_owner','invalid_name','rate_limited','invalid_request'].includes(error.code) ? error.code : 'storage_failed';
          response.message = response.code === 'storage_failed' ? '保存图片失败，请稍后重试。' : error.message;
        }
        send(ws, response); return;
      }
      if (galleryOnly) { reject(ws, 'invalid_request', '此连接只用于公共图片库。'); return; }
      if (!member) {
        if (packet.type !== 'hello' || packet.version !== 1 || !validName(packet.name)) {
          reject(ws, 'invalid_hello', '协议或名字不正确，请更新客户端。'); return;
        }
        if (packet.action === 'create') {
          for (const existing of rooms.values()) prune(existing);
          if (rooms.size >= maxRooms) { reject(ws, 'server_full', '服务器房间已满，请稍后重试。'); return; }
          let code;
          do { code = Array.from(randomBytes(12), (byte) => alphabet[byte & 31]).join(''); } while (rooms.has(code));
          room = { code, members: new Map() }; rooms.set(code, room);
        } else if (['join', 'resume'].includes(packet.action) && validRoom(packet.room)) {
          room = rooms.get(packet.room);
          if (room) prune(room);
          room = rooms.get(packet.room);
          if (!room) { reject(ws, 'room_missing', '房间不存在或已过期，请让朋友重新创建房间。'); return; }
        } else { reject(ws, 'invalid_room', '房间码格式不正确。'); return; }
        if (packet.action === 'resume') {
          if (typeof packet.token !== 'string' || !/^[0-9a-f]{64}$/.test(packet.token)) {
            reject(ws, 'invalid_token', '重连凭证无效，请重新加入房间。'); return;
          }
          member = [...room.members.values()].find((candidate) =>
            timingSafeEqual(Buffer.from(candidate.token), Buffer.from(packet.token)));
          if (!member) { reject(ws, 'resume_expired', '重连已超时，请重新加入房间。'); return; }
          if (member.ws) { member.ws.close(1008, 'session_replaced'); }
          member.ws = ws; member.disconnectedAt = null;
        } else {
          if (room.members.size >= 2) { reject(ws, 'room_full', '房间已满；断线成员会保留席位 60 秒。'); return; }
          member = { id: randomUUID(), token: randomBytes(32).toString('hex'), name: packet.name.trim(), ws,
            disconnectedAt: null, recentIDs: [] };
          room.members.set(member.id, member);
        }
        member.emotes = Array.isArray(packet.capabilities) && packet.capabilities.includes(emoteCapability);
        clearTimeout(authTimer);
        send(ws, { type: 'welcome', version: 1, room: room.code, token: member.token,
          memberID: member.id, peers: roster(room), capabilities: [emoteCapability] });
        broadcastPeers(room); return;
      }
      // A replaced transport can never send using its former member identity.
      if (member.ws !== ws) { ws.close(1008, 'session_replaced'); return; }
      if (packet.type === 'leave') {
        room.members.delete(member.id); member.ws = null;
        broadcastPeers(room); prune(room); ws.close(1000, 'left'); return;
      }
      if (packet.type === 'emote') {
        if (!member.emotes || !validUUID(packet.eventID) || !validEmote(packet.emote)) {
          reject(ws, 'invalid_emote', '表情格式不正确。'); return;
        }
        const eventID = packet.eventID.toLowerCase();
        if (member.recentIDs.includes(eventID)) return;
        if (now-lastEmote < 1000) { send(ws, { type: 'error', code: 'rate_limited' }); return; }
        lastEmote = now;
        member.recentIDs.push(eventID); if (member.recentIDs.length > 128) member.recentIDs.shift();
        const outgoing = { type: 'emote', eventID,
          emote: { id: packet.emote.id, name: packet.emote.name, png: packet.emote.png }, sender: { id: member.id, name: member.name } };
        for (const peer of room.members.values()) if (peer !== member && peer.ws && peer.emotes) send(peer.ws, outgoing);
        if ([...room.members.values()].some((peer) => peer !== member && peer.ws && !peer.emotes)) {
          send(ws, { type: 'error', code: 'emote_unsupported', message: '朋友需要更新至 1.5.0 才能接收表情。' });
        }
        return;
      }
      if (data.length > 4096) { reject(ws, 'invalid_message', '信号消息过大。'); return; }
      if (packet.type !== 'ping' || !validUUID(packet.eventID) || !kinds.has(packet.kind)) {
        reject(ws, 'invalid_ping', '信号格式不正确。'); return;
      }
      const eventID = packet.eventID.toLowerCase();
      if (member.recentIDs.includes(eventID)) return;
      member.recentIDs.push(eventID);
      if (member.recentIDs.length > 128) member.recentIDs.shift();
      const outgoing = { type: 'ping', eventID, kind: packet.kind, sender: { id: member.id, name: member.name } };
      // Transient events: no storage, no sender echo, no cross-room broadcast.
      for (const peer of room.members.values()) if (peer !== member && peer.ws) send(peer.ws, outgoing);
    });
    ws.on('close', () => {
      clearTimeout(authTimer);
      const count = (byAddress.get(address) ?? 1)-1;
      if (count <= 0) byAddress.delete(address); else byAddress.set(address, count);
      if (member?.ws === ws) {
        member.ws = null; member.disconnectedAt = Date.now(); broadcastPeers(room);
      }
    });
  });
  const sweep = setInterval(() => {
    for (const room of rooms.values()) prune(room);
    for (const [address, window] of uploadWindows) if (Date.now()-window.start >= 60_000) uploadWindows.delete(address);
  }, Math.min(graceMs, 5000));
  const heartbeat = setInterval(() => { for (const ws of wss.clients) ws.checkAlive(); }, heartbeatMs);
  sweep.unref(); heartbeat.unref();
  return {
    server,
    async listen(port = 8787, host = '127.0.0.1') {
      await new Promise((resolve, reject) => { server.once('error', reject); server.listen(port, host, resolve); });
      return server.address();
    },
    async close() {
      clearInterval(sweep); clearInterval(heartbeat);
      for (const ws of wss.clients) ws.terminate();
      await new Promise((resolve) => wss.close(resolve));
      await new Promise((resolve) => server.close(resolve));
      rooms.clear();
    }
  };
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const port = Number(process.env.PORT ?? 8787);
  if (!Number.isInteger(port) || port < 1 || port > 65535) throw new Error('PORT must be between 1 and 65535');
  const relay = createRelay({ trustProxy: process.env.TRUST_PROXY === '1', galleryDirectory: process.env.GALLERY_DIRECTORY || null });
  await relay.listen(port, process.env.HOST ?? '127.0.0.1');
  console.log(`LoLPing relay listening on port ${port}; protocol 1`);
  let stopping = false;
  const stop = async () => { if (stopping) return; stopping = true; await relay.close(); process.exit(0); };
  process.on('SIGTERM', stop); process.on('SIGINT', stop);
}

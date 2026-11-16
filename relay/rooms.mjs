import { mkdirSync, readFileSync, writeFileSync, renameSync, existsSync, unlinkSync } from 'node:fs';
import { join } from 'node:path';
import { randomUUID } from 'node:crypto';

export class RoomStore {
  constructor(directory, { retentionMs, maxRooms, validRoom, validUUID, validName, validCounter = () => false }) {
    this.directory = directory; this.retentionMs = retentionMs; this.maxRooms = maxRooms;
    mkdirSync(directory, { recursive: true, mode: 0o700 });
    this.rooms = new Map();
    const file = join(directory, 'rooms.json');
    if (!existsSync(file)) return;
    const manifest = JSON.parse(readFileSync(file, 'utf8'));
    if (manifest.version !== 1 || !Array.isArray(manifest.rooms) || manifest.rooms.length > maxRooms) throw new Error('Invalid room manifest');
    for (const value of manifest.rooms) {
      if (!validRoom(value.code) || !Array.isArray(value.members) || value.members.length > 2 || this.rooms.has(value.code)) throw new Error('Invalid saved room');
      if (value.counter !== undefined && !validCounter(value.counter)) throw new Error('Invalid saved counter');
      const room = { code: value.code, members: new Map() };
      if (value.counter) room.counter = { day: value.counter.day, today: value.counter.today, total: value.counter.total };
      for (const m of value.members) {
        if (!validUUID(m.id) || !validName(m.name) || typeof m.tokenHash !== 'string' || !/^[0-9a-f]{64}$/.test(m.tokenHash) ||
            !Number.isSafeInteger(m.disconnectedAt) || m.disconnectedAt < 0 || room.members.has(m.id) ||
            (m.counterSeeded !== undefined && typeof m.counterSeeded !== 'boolean')) throw new Error('Invalid saved member');
        if (Date.now()-m.disconnectedAt < retentionMs) room.members.set(m.id, { ...m, ws: null, token: null, recentIDs: [] });
      }
      if (room.members.size) this.rooms.set(room.code, room);
    }
  }
  save(rooms) {
    const now = Date.now();
    const values = [...rooms.values()].map(room => ({ code: room.code, ...(room.counter ? { counter: room.counter } : {}),
      members: [...room.members.values()].map(m => ({
        id: m.id, name: m.name, tokenHash: m.tokenHash, disconnectedAt: m.ws ? now : m.disconnectedAt,
        ...(m.counterSeeded ? { counterSeeded: true } : {})
      })) }));
    const temp = join(this.directory, 'rooms-'+randomUUID()+'.tmp');
    try {
      writeFileSync(temp, JSON.stringify({ version: 1, rooms: values }), { mode: 0o600 });
      renameSync(temp, join(this.directory, 'rooms.json'));
    } finally { if (existsSync(temp)) unlinkSync(temp); }
  }
}

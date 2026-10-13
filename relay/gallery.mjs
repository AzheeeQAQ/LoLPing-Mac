import { mkdirSync, readFileSync, writeFileSync, renameSync, unlinkSync, existsSync } from 'node:fs';
import { join } from 'node:path';
import { randomBytes, randomUUID, createHash, timingSafeEqual } from 'node:crypto';

export const validAssetID = (id) => typeof id === 'string' && /^[0-9a-f]{64}$/.test(id);
const digest = (text) => createHash('sha256').update(text).digest('hex');
const fail = (code, message) => Object.assign(new Error(message), { code });
const displayName = (value) => Array.from(value.normalize('NFC').replace(/[\p{Cc}\p{Cf}]/gu, '')).slice(0,24).join('').trim() || '玩家';

// Only normalized PNGs and explicit user uploads enter this persistent public store.
export class GalleryStore {
  constructor(directory, { maxItems = 500, validate } = {}) {
    if (!Number.isInteger(maxItems) || maxItems < 1 || maxItems > 5000) throw new Error('Invalid gallery item limit');
    this.directory = directory; this.maxItems = maxItems; this.validate = validate; this.items = new Map();
    mkdirSync(directory, { recursive: true, mode: 0o700 });
    const index = join(directory, 'index.json');
    if (existsSync(index)) {
      const manifest = JSON.parse(readFileSync(index, 'utf8'));
      if (manifest.version !== 1 || !Array.isArray(manifest.items) || manifest.items.length > maxItems) throw new Error('Invalid gallery index');
      for (const entry of manifest.items) {
        if (!validAssetID(entry.id) || !validAssetID(entry.ownerHash) || typeof entry.uploader !== 'string' ||
            !Number.isSafeInteger(entry.createdAt) || this.items.has(entry.id)) throw new Error('Invalid gallery entry');
        const png = readFileSync(join(directory, entry.id+'.png')).toString('base64');
        if (!validate({ id: entry.id, name: entry.name, png }) || !validate({ id: entry.id, name: entry.uploader, png })) throw new Error('Invalid stored image');
        entry.name = displayName(entry.name); entry.uploader = displayName(entry.uploader);
        this.items.set(entry.id, entry);
      }
    }
  }
  save() {
    const temp = join(this.directory, 'index-'+randomUUID()+'.tmp');
    try {
      writeFileSync(temp, JSON.stringify({ version: 1, items: [...this.items.values()] }), { mode: 0o600 });
      renameSync(temp, join(this.directory, 'index.json'));
    } finally { if (existsSync(temp)) unlinkSync(temp); }
  }
  publicEntry(entry) { return { id: entry.id, name: entry.name, uploader: entry.uploader, createdAt: entry.createdAt }; }
  list(cursor = 0) {
    if (!Number.isSafeInteger(cursor) || cursor < 0 || cursor > this.maxItems) throw fail('invalid_cursor', '图片库分页参数无效。');
    const all = [...this.items.values()].sort((a,b) => b.createdAt-a.createdAt || a.id.localeCompare(b.id));
    return { items: all.slice(cursor, cursor+50).map(e => this.publicEntry(e)), total: all.length,
      nextCursor: cursor+50 < all.length ? cursor+50 : null };
  }
  get(id) {
    if (!validAssetID(id)) throw fail('invalid_asset', '图片编号无效。');
    const entry = this.items.get(id);
    if (!entry) throw fail('asset_missing', '图片已被删除，请刷新公共库。');
    const png = readFileSync(join(this.directory, id+'.png')).toString('base64');
    return { emote: { id, name: entry.name, png }, item: this.publicEntry(entry) };
  }
  upload(emote, uploader, ownerToken = randomBytes(32).toString('hex')) {
    if (!this.validate(emote) || !this.validate({ ...emote, name: uploader })) throw fail('invalid_emote', '请选择有效的表情图片。');
    if (!validAssetID(ownerToken)) throw fail('not_owner', '上传凭证无效。');
    const existing = this.items.get(emote.id);
    if (existing) return { item: this.publicEntry(existing), duplicate: true,
      owned: timingSafeEqual(Buffer.from(existing.ownerHash, 'hex'), Buffer.from(digest(ownerToken), 'hex')) };
    if (this.items.size >= this.maxItems) throw fail('gallery_full', '公共图片库已满，请先删除自己的旧图片。');
    const entry = { id: emote.id, name: displayName(emote.name), uploader: displayName(uploader), createdAt: Date.now(), ownerHash: digest(ownerToken) };
    const file = join(this.directory, emote.id+'.png');
    writeFileSync(file, Buffer.from(emote.png, 'base64'), { mode: 0o600 });
    this.items.set(emote.id, entry);
    try { this.save(); } catch (error) { this.items.delete(emote.id); unlinkSync(file); throw error; }
    return { item: this.publicEntry(entry), ownerToken, owned: true, duplicate: false };
  }
  remove(id, ownerToken) {
    if (!validAssetID(id) || !validAssetID(ownerToken)) throw fail('not_owner', '只能删除自己上传的图片。');
    const entry = this.items.get(id);
    if (!entry) throw fail('asset_missing', '图片已被删除，请刷新公共库。');
    if (!timingSafeEqual(Buffer.from(entry.ownerHash, 'hex'), Buffer.from(digest(ownerToken), 'hex'))) throw fail('not_owner', '只能删除自己上传的图片。');
    this.items.delete(id);
    try { this.save(); } catch (error) { this.items.set(id, entry); throw error; }
    // Remove index first: a crash can leave an unlisted blob, never a broken index.
    try { unlinkSync(join(this.directory, id+'.png')); } catch {}
    return { id };
  }
}

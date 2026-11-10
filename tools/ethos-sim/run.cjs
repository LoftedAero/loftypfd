// Runs Ethos Suite's X20 simulator headless and saves what the screen shows.
//
//   node tools/ethos-sim/run.cjs [--scripts dist/ethos/scripts] [--ms 8000]
//        [--shot out/ethos/screen.png] [--tap X,Y@MS ...] [--every MS]
//        [--sim DIR] [--sport RECORDING [--sport-at MS]]
//
// The simulator is an Emscripten build that Ethos Suite installs under
// %APPDATA%\Ethos Suite\.simulator. It boots in Node with an in-memory
// filesystem: the radio settings and models are copied from Ethos Suite's
// own simulator storage (read, never written), the scripts from --scripts.
// Each frame arrives at Module.updateCanvas as RGB565, bottom row first.
// Lua's print and errors go to stdout.
'use strict'
const fs = require('fs')
const path = require('path')
const zlib = require('zlib')

const args = process.argv.slice(2)
const opt = (name, fallback) => {
  const i = args.indexOf(name)
  return i >= 0 ? args[i + 1] : fallback
}
const all = (name) => args.flatMap((a, i) => (a === name ? [args[i + 1]] : []))

const ROOT = path.resolve(__dirname, '..', '..')
const SUITE = path.join(process.env.APPDATA, 'Ethos Suite', '.simulator')
const version = opt('--version', fs.readdirSync(SUITE).filter((d) => /^\d/.test(d)).sort().pop())
const radioDir = fs.readdirSync(path.join(SUITE, version)).find((d) => d !== 'persist')
const board = fs.readdirSync(path.join(SUITE, version, 'persist'))[0]
const scripts = path.resolve(ROOT, opt('--scripts', 'dist/ethos/scripts'))
const runMs = Number(opt('--ms', 8000))
const shot = path.resolve(ROOT, opt('--shot', 'out/ethos/screen.png'))
const every = Number(opt('--every', 0))
// --models DIR runs with these model files instead of Ethos Suite's own;
// --save-models DIR keeps the models as the run left them, so a screen set
// up once through the menus becomes a fixture.
const models = opt('--models', null)
const saveModels = opt('--save-models', null)
const taps = all('--tap').map((t) => {
  const [xy, at] = t.split('@')
  const [x, y] = xy.split(',').map(Number)
  return { x, y, at: Number(at) }
})
// --press X,Y@MS: a long press, as Ethos Suite sends one: down, the
// simulator's long-press call after a second, then up.
const presses = all('--press').map((t) => {
  const [xy, at] = t.split('@')
  const [x, y] = xy.split(',').map(Number)
  return { x, y, at: Number(at) }
})
// --key NAME@MS[:HOLD_MS]: a PC key as Ethos Suite sends one (the firmware
// maps Home, PageUp, PageDown, Enter, Delete and the arrows to radio keys).
const keys = all('--key').map((t) => {
  const [name, rest] = t.split('@')
  const [at, hold] = rest.split(':').map(Number)
  return { name, at, hold: hold || 150 }
})
// --drag X1,Y1,X2,Y2@MS: a finger dragged over 300 ms, to scroll a list.
const drags = all('--drag').map((t) => {
  const [pts, at] = t.split('@')
  const [x1, y1, x2, y2] = pts.split(',').map(Number)
  return { x1, y1, x2, y2, at: Number(at) }
})

// --sport RECORDING plays a SITL recording (tools/sitl.py record
// --passthrough) into the radio as S.Port passthrough, the words a FrSky
// receiver would deliver, at their recorded times. The whole-message status
// frames are left out: S.Port has only the words.
const sportFile = opt('--sport', null)

function passthroughWords(file) {
  const out = []
  for (const line of fs.readFileSync(path.resolve(ROOT, file), 'utf8').split(/\r?\n/)) {
    const [t, type, hex] = line.trim().split(' ')
    if (!hex || (Number(type) !== 0x80 && Number(type) !== 0x7f)) continue
    const d = Buffer.from(hex, 'hex')
    const at = Number(t) * 1000
    if (d[0] === 0xf0 && d.length >= 7) out.push({ at, appId: d.readUInt16LE(1), value: d.readUInt32LE(3) })
    else if (d[0] === 0xf2) {
      for (let k = 0; k < d[1] && 2 + k * 6 + 6 <= d.length; k++) {
        out.push({ at, appId: d.readUInt16LE(2 + k * 6), value: d.readUInt32LE(4 + k * 6) })
      }
    }
  }
  return out
}

// The glue is an Emscripten MODULARIZE build with no CommonJS export; a copy
// with one added is what its worker threads load too.
// The folder is named like X20PRO-FCC; the files and the factory, X20PRO_FCC.
// --sim DIR runs another build, unpacked from FrSky's WebSimulator zip, with
// Ethos Suite's settings and models.
const simDir = opt('--sim', null)
const radioPath = simDir ? path.resolve(ROOT, simDir) : path.join(SUITE, version, radioDir)
const factory = fs.readdirSync(radioPath).find((f) => f.endsWith('.js')).slice(0, -3)
const glue = path.join(radioPath, factory + '.js')
const cache = path.join(ROOT, 'out', 'ethos-sim', simDir ? path.basename(radioPath) : version)
fs.mkdirSync(cache, { recursive: true })
const loader = path.join(cache, factory + '.cjs')
if (!fs.existsSync(loader) || fs.statSync(loader).mtimeMs < fs.statSync(glue).mtimeMs) {
  fs.writeFileSync(loader, fs.readFileSync(glue, 'utf8') + `\nmodule.exports = ${factory};\n`)
}

function png(w, h, px) {
  const raw = Buffer.alloc((w * 3 + 1) * h)
  for (let y = 0; y < h; y++) {
    const src = (h - 1 - y) * w
    const row = y * (w * 3 + 1)
    for (let x = 0; x < w; x++) {
      const v = px[src + x]
      const o = row + 1 + x * 3
      raw[o] = (((v >> 11) & 31) * 255) / 31
      raw[o + 1] = (((v >> 5) & 63) * 255) / 63
      raw[o + 2] = ((v & 31) * 255) / 31
    }
  }
  const table = []
  for (let n = 0; n < 256; n++) {
    let c = n
    for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1
    table[n] = c >>> 0
  }
  const crc = (b) => {
    let c = 0xffffffff
    for (const x of b) c = table[(c ^ x) & 255] ^ (c >>> 8)
    return (c ^ 0xffffffff) >>> 0
  }
  const chunk = (type, data) => {
    const len = Buffer.alloc(4)
    len.writeUInt32BE(data.length)
    const td = Buffer.concat([Buffer.from(type), data])
    const c = Buffer.alloc(4)
    c.writeUInt32BE(crc(td))
    return Buffer.concat([len, td, c])
  }
  const head = Buffer.alloc(13)
  head.writeUInt32BE(w, 0)
  head.writeUInt32BE(h, 4)
  head[8] = 8
  head[9] = 2
  return Buffer.concat([
    Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]),
    chunk('IHDR', head),
    chunk('IDAT', zlib.deflateSync(raw)),
    chunk('IEND', Buffer.alloc(0)),
  ])
}

function copyIn(FS, from, to, skip) {
  for (const e of fs.readdirSync(from, { withFileTypes: true })) {
    if (skip && skip(e.name)) continue
    const src = path.join(from, e.name)
    const dst = to + '/' + e.name
    if (e.isDirectory()) {
      try {
        FS.mkdir(dst)
      } catch {}
      copyIn(FS, src, dst)
    } else FS.writeFile(dst, fs.readFileSync(src))
  }
}

;(async () => {
  let last = null
  const M = await require(loader)({
    wasmBinary: fs.readFileSync(path.join(radioPath, factory + '.wasm')),
    print: (t) => console.log(t.replace(/\x1b\[[0-9;]*m/g, '')),
    printErr: () => {},
  })
  M.updateCanvas = (w, h, p) => {
    last = { w, h, px: new Uint16Array(M.HEAPU16.buffer, p, w * h).slice() }
  }
  const FS = M.FS
  const root = '/persist/' + board
  FS.mkdir('/persist')
  FS.mkdir(root)
  copyIn(FS, path.join(SUITE, version, 'persist', board), root, (n) => n === 'scripts' || (models && n === 'models'))
  if (models) {
    FS.mkdir(root + '/models')
    copyIn(FS, path.resolve(ROOT, models), root + '/models')
  }
  FS.mkdir(root + '/scripts')
  if (fs.existsSync(scripts)) copyIn(FS, scripts, root + '/scripts')
  M._start()

  const save = (file) => {
    if (!last) return
    fs.mkdirSync(path.dirname(file), { recursive: true })
    fs.writeFileSync(file, png(last.w, last.h, last.px))
  }
  for (const t of taps) {
    setTimeout(() => {
      M.ccall('onMouseDown', 'void', ['number', 'number'], [t.x, t.y])
      setTimeout(() => M.ccall('onMouseUp', 'void', ['number', 'number'], [t.x, t.y]), 120)
    }, t.at)
  }
  for (const k of keys) {
    const send = (down) => M.ccall('onKeyEvent', 'boolean', ['number', 'string', 'number', 'number'], [0, k.name, 0, down ? 1 : 0])
    setTimeout(() => send(true), k.at)
    setTimeout(() => send(false), k.at + k.hold)
  }
  for (const p of presses) {
    setTimeout(() => M.ccall('onMouseDown', 'void', ['number', 'number'], [p.x, p.y]), p.at)
    setTimeout(() => M.ccall('onMouseLongPress', 'void', [], []), p.at + 1000)
    setTimeout(() => M.ccall('onMouseUp', 'void', ['number', 'number'], [p.x, p.y]), p.at + 1100)
  }
  for (const d of drags) {
    const call = (fn, x, y) => M.ccall(fn, 'void', ['number', 'number'], [Math.round(x), Math.round(y)])
    setTimeout(() => call('onMouseDown', d.x1, d.y1), d.at)
    for (let k = 1; k <= 10; k++) {
      setTimeout(() => call('onMouseMove', d.x1 + ((d.x2 - d.x1) * k) / 10, d.y1 + ((d.y2 - d.y1) * k) / 10), d.at + k * 30)
    }
    setTimeout(() => call('onMouseUp', d.x2, d.y2), d.at + 330)
  }
  if (sportFile) {
    const words = passthroughWords(sportFile)
    const start = Number(opt('--sport-at', 2000))
    const types = ['number', 'number', 'number', 'number', 'number', 'number', 'number']
    let next = 0
    const t0 = Date.now()
    // Module 0, band 0, receiver 0, as Ethos Suite's own telemetry simulator
    // sends; ArduPilot's passthrough sensor is physical ID 0x1B.
    setInterval(() => {
      const now = Date.now() - t0 - start
      for (; next < words.length && words[next].at <= now; next++) {
        const { appId, value } = words[next]
        M.ccall('injectSPortFrame', 'void', types, [0, 0, 0, 0x1b, 0x10, appId, value | 0])
      }
    }, 10)
    console.log(`playing ${words.length} passthrough words from ${sportFile}`)
  }
  if (every > 0) {
    let n = 0
    setInterval(() => save(shot.replace(/\.png$/, `-${String(++n).padStart(2, '0')}.png`)), every)
  }
  setTimeout(() => {
    save(shot)
    console.log(`saved ${path.relative(ROOT, shot)}`)
    if (saveModels) {
      const out = path.resolve(ROOT, saveModels)
      fs.mkdirSync(out, { recursive: true })
      for (const f of FS.readdir(root + '/models').filter((n) => n !== '.' && n !== '..')) {
        fs.writeFileSync(path.join(out, f), FS.readFile(root + '/models/' + f))
      }
      console.log(`saved models to ${path.relative(ROOT, out)}`)
    }
    process.exit(0)
  }, runMs)
})().catch((e) => {
  console.error(e)
  process.exit(1)
})

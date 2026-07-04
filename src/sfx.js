// src/sfx.js — WebAudio 程序合成音效(无外部素材);localStorage 记住静音偏好
let ctx = null;
let muted = typeof localStorage !== 'undefined' && localStorage.getItem('biaofen.muted') === '1';

function ac() {
  if (!ctx) ctx = new (window.AudioContext || window.webkitAudioContext)();
  if (ctx.state === 'suspended') ctx.resume();
  return ctx;
}

// 单音:freq→(可选滑到 glide)的短促音
function tone(freq, dur, { type = 'sine', gain = 0.15, when = 0, glide = 0 } = {}) {
  if (muted) return;
  try {
    const a = ac(), t0 = a.currentTime + when;
    const o = a.createOscillator(), g = a.createGain();
    o.type = type;
    o.frequency.setValueAtTime(freq, t0);
    if (glide) o.frequency.exponentialRampToValueAtTime(glide, t0 + dur);
    g.gain.setValueAtTime(gain, t0);
    g.gain.exponentialRampToValueAtTime(0.001, t0 + dur);
    o.connect(g).connect(a.destination);
    o.start(t0);
    o.stop(t0 + dur + 0.02);
  } catch { /* 音频不可用时静默 */ }
}

// 白噪声短爆:出牌的"啪"
function noise(dur, { gain = 0.12 } = {}) {
  if (muted) return;
  try {
    const a = ac(), t0 = a.currentTime;
    const len = Math.max(1, (a.sampleRate * dur) | 0);
    const buf = a.createBuffer(1, len, a.sampleRate);
    const d = buf.getChannelData(0);
    for (let i = 0; i < len; i++) d[i] = (Math.random() * 2 - 1) * (1 - i / len);
    const src = a.createBufferSource();
    src.buffer = buf;
    const g = a.createGain();
    g.gain.value = gain;
    src.connect(g).connect(a.destination);
    src.start(t0);
  } catch { /* 静默 */ }
}

export const SFX = {
  get muted() { return muted; },
  toggle() {
    muted = !muted;
    try { localStorage.setItem('biaofen.muted', muted ? '1' : '0'); } catch { /* 忽略 */ }
    return muted;
  },
  select() { tone(1500, 0.04, { type: 'triangle', gain: 0.08 }); },
  play() { noise(0.06); },
  trick() { tone(880, 0.09); tone(1320, 0.14, { when: 0.07 }); },
  bid() { tone(520, 0.08, { type: 'triangle' }); },
  trump() { tone(523, 0.08); tone(659, 0.08, { when: 0.08 }); tone(784, 0.12, { when: 0.16 }); },
  win() { tone(523, 0.3); tone(659, 0.3, { when: 0.02 }); tone(784, 0.35, { when: 0.04 }); },
  lose() { tone(392, 0.2, { glide: 330 }); tone(294, 0.3, { when: 0.18, glide: 240 }); },
};

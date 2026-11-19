"""Fit Pulse's keyboard boards to reference recordings.

Each key group's sound becomes a matrix: level in dB for 21 third-octave
noise bands (100 Hz-10 kHz) at 17 moments in the first 140 ms. Pulse
resynthesises it from fresh noise: each band's noise is shaped by its levels
and only then band-passed, so a band stays in its band however quickly it
moves (shaping after the filter would splatter a quick low thock up into the
mids). No recording is reproduced; the references (Mechvibes community packs)
are only measured here.

    python3 fit.py '{"thingy": "/path/creamy", ...}' recipes.json
"""
import json, sys, wave, math
import numpy as np

SR = 48000
BANDS = [100 * 2 ** (k / 3) for k in range(21)]            # 100 Hz ... 10.2 kHz
# Per stage. Two stages in series make each band a third of an octave wide,
# but never narrower than the group's low width: a narrow low band rings for
# tens of milliseconds, right for a case's resonance, while a creamy thock is
# a short, wide burst. The fit picks the width per key group.
WIDTHS = (150, 80, 30)  # Hz


def qs(width):
    return [min(2.8, 0.6436 * f / width) for f in BANDS]


WIDTH = [150]  # The width in use (set by fit).
TIMES = [0, 1, 2, 3, 4, 6, 8, 11, 15, 20, 27, 36, 48, 64, 85, 110, 140]  # ms
FLOOR = -72  # Silence: a cell at the floor plays nothing.
WINDOW_MS = 60  # What's matched: the strike and its ring.

GROUPS = {
    'text': lambda k: k.startswith('Key') or k.startswith('Digit') or k in ('Comma', 'Period', 'Slash', 'Semicolon', 'Quote', 'BracketLeft', 'BracketRight', 'Backslash', 'Minus', 'Equal', 'Backquote'),
    'space': lambda k: k == 'Space',
    'returnKey': lambda k: k in ('Enter', 'NumpadEnter'),
    'delete': lambda k: k in ('Backspace', 'Delete'),
    'navigation': lambda k: k.startswith('Arrow') or k in ('Tab', 'Escape', 'Home', 'End', 'PageUp', 'PageDown') or (k.startswith('F') and k[1:].isdigit()),
    'modifier': lambda k: any(k.startswith(p) for p in ('Shift', 'Meta', 'Alt', 'Control', 'CapsLock')),
}

# ------------------------------------------------------------------ input

def load(path):
    w = wave.open(path)
    n, ch, sr, width = w.getnframes(), w.getnchannels(), w.getframerate(), w.getsampwidth()
    x = np.frombuffer(w.readframes(n), dtype={2: np.int16, 4: np.int32}[width]).astype(np.float64)
    x = x.reshape(-1, ch).mean(axis=1) / (32768.0 if width == 2 else 2 ** 31)
    if sr != SR:
        t = np.arange(int(len(x) * SR / sr)) * sr / SR
        x = np.interp(t, np.arange(len(x)), x)
    return x


def pack_slices(folder):
    cfg = json.load(open(f'{folder}/config.json'))
    name = cfg.get('audio_file') or 'concatenated_audio.wav'
    audio = load(f'{folder}/' + (name.rsplit('.', 1)[0] + '.wav'))  # Ogg packs are converted with afconvert first.
    out = {}
    for key, value in cfg['definitions'].items():
        start, end = value['timing'][0]
        seg = audio[int(start / 1000 * SR):int(end / 1000 * SR)]
        if len(seg) > 64:
            out[key] = seg
    return out


def group_refs(slices, group):
    """The group's distinct sounds (packs reuse one sound for many keys)."""
    def distinct(test):
        refs, seen = [], set()
        for key, seg in slices.items():
            sig = (len(seg), round(float(seg[:200].sum()), 6))
            if test(key) and sig not in seen:
                seen.add(sig)
                refs.append(seg)
        return refs
    return distinct(GROUPS[group]) or distinct(GROUPS['text'])


def onset(x):
    """The strike: the first quarter-of-peak sample, less 1.5 ms. (A lower
    threshold can catch handling noise long before the key itself.)"""
    peak = np.max(np.abs(x))
    i = int(np.argmax(np.abs(x) > 0.25 * peak))
    return max(i - int(0.0015 * SR), 0)

# -------------------------------------------------------------- filtering

def bp_coefs(f0, q):
    w0 = 2 * math.pi * f0 / SR
    alpha = math.sin(w0) / (2 * q)
    a0 = 1 + alpha
    return (alpha / a0, 0.0, -alpha / a0, -2 * math.cos(w0) / a0, (1 - alpha) / a0)


def response(coefs, n):
    """Two identical sections in series, at the rfft bins of length n."""
    b0, b1, b2, a1, a2 = coefs
    z = np.exp(-1j * 2 * np.pi * np.fft.rfftfreq(n))
    h = (b0 + b1 * z + b2 * z * z) / (1 + a1 * z + a2 * z * z)
    return h * h


TAIL = 16384  # Enough for the lowest band's ring to die away.
_cache = {}


def bandpass(x, band):
    n = 1 << int(math.ceil(math.log2(len(x) + TAIL)))
    key = (band, n, WIDTH[0])
    if key not in _cache:
        _cache[key] = response(bp_coefs(BANDS[band], qs(WIDTH[0])[band]), n)
    return np.fft.irfft(np.fft.rfft(x, n) * _cache[key], n)[:len(x)]


def unit_rms(band, width):
    """RMS of uniform noise in -1...1 through the band: sqrt(sum h^2 / 3)."""
    n = 1 << 16
    h = np.fft.irfft(response(bp_coefs(BANDS[band], qs(width)[band]), n), n)
    return math.sqrt(float(np.sum(h * h)) / 3)


UNITS = {w: [unit_rms(b, w) for b in range(len(BANDS))] for w in WIDTHS}

# ------------------------------------------------------------- measuring

def smoothing(band):
    """A band can't change faster than its bandwidth allows."""
    bw = 0.6436 * BANDS[band] / qs(WIDTH[0])[band]
    return min(max(1.0 / bw, 0.001), 0.012)


def envelope(x):
    """Band power at each moment from the onset, shape (bands, times)."""
    x = x[onset(x):]
    x = np.concatenate([x, np.zeros(int(0.16 * SR))])[:int(0.16 * SR)]
    out = np.zeros((len(BANDS), len(TIMES)))
    for b in range(len(BANDS)):
        p = bandpass(x, b) ** 2
        width = int(smoothing(b) * SR) | 1
        p = np.convolve(p, np.hanning(width + 2)[1:-1] / np.hanning(width + 2)[1:-1].sum(), mode='same')
        out[b] = p[[min(int(t / 1000 * SR), len(p) - 1) for t in TIMES]]
    return out + 1e-20


CENTRES = [100 * 2 ** (k / 3) for k in range(23)]  # The spectrum check: 100 Hz-16 kHz.


# The strike and the tail, matched separately: a strike's click and a tail's
# body are different sounds. Milliseconds from the onset.
REGIONS = ((0, 6), (6, WINDOW_MS))


def spectrum(x, start_ms, end_ms):
    """Third-octave power from start to end, flat, with 0.5 ms tapers."""
    x = x[onset(x):]
    seg = x[int(start_ms / 1000 * SR):int(end_ms / 1000 * SR)]
    seg = np.pad(seg, (0, max(0, int((end_ms - start_ms) / 1000 * SR) - len(seg))))
    taper = int(0.0005 * SR)
    window = np.ones(len(seg))
    window[-taper:] = np.linspace(1, 0, taper)
    if start_ms > 0:
        window[:taper] = np.linspace(0, 1, taper)
    f = np.fft.rfftfreq(16384, 1 / SR)
    p = np.abs(np.fft.rfft(seg * window, 16384)) ** 2
    return np.array([p[(f >= c / 2 ** (1 / 6)) & (f < c * 2 ** (1 / 6))].sum() for c in CENTRES]) + 1e-20


def mean_spectrum(xs):
    """Shape of each region's spectrum, shape (regions, centres)."""
    def one(x, region):
        p = spectrum(x, *region)
        return p / p.sum()
    return np.array([np.mean([one(x, region) for x in xs], axis=0) for region in REGIONS])


def mean_envelope(xs):
    return np.mean([envelope(x) / envelope(x).max() for x in xs], axis=0)


def db(p):
    return np.maximum(10 * np.log10(p / p.max()), FLOOR)

# ------------------------------------------------------------ synthesis

def synth(recipe, length_ms, seed=1):
    """Renders the way Pulse's Swift does: shape each band's noise, then
    band-pass it, sum, and fade the last 5 ms."""
    n = int(length_ms / 1000 * SR)
    t = np.arange(n) / SR * 1000
    rng = np.random.default_rng(seed)
    out = np.zeros(n)
    for b in range(len(BANDS)):
        noise = rng.uniform(-1, 1, n)
        if recipe[b].max() <= FLOOR + 0.5:
            continue
        level = np.interp(t, TIMES, recipe[b])
        out += bandpass(noise * np.where(level > FLOOR + 0.5, 10 ** (level / 20), 0), b) / UNITS[WIDTH[0]][b]
    fade = int(0.005 * SR)
    out[-fade:] *= np.linspace(1, 0, fade)
    return out


SEEDS = (11, 12, 13, 14)

# --------------------------------------------------------------- fitting

def frames(x, ms=2, total=WINDOW_MS):
    """Energy in 2 ms frames from the onset: how the key dies away."""
    x = x[onset(x):]
    n = int(ms / 1000 * SR)
    x = np.pad(x, (0, max(0, int(total / 1000 * SR) - len(x))))
    e = np.array([np.mean(x[i * n:(i + 1) * n] ** 2) for i in range(total // ms)]) + 1e-20
    return e / e.sum()


def mean_frames(xs):
    return np.mean([frames(x) for x in xs], axis=0)


def errors(recipe, length_ms, target_env, target_spec, target_frames):
    takes = [synth(recipe, length_ms, s) for s in SEEDS]
    env, spec, fr = mean_envelope(takes), mean_spectrum(takes), mean_frames(takes)
    te, me = db(target_env), db(env)
    live = (te > -40) | (me > -40)
    env_error = float(np.abs(np.clip(me - te, -20, 20))[live].mean())
    ts = 10 * np.log10(target_spec / target_spec.max(axis=1, keepdims=True))
    ms = 10 * np.log10(spec / spec.max(axis=1, keepdims=True))
    live = (ts > -35) | (ms > -35)
    spec_error = float(np.abs(np.clip(ms - ts, -20, 20))[live].mean())
    # Gentle above all: any extra share of energy above 2.5 kHz counts in full.
    high = np.array(CENTRES) >= 2500
    for region in range(len(REGIONS)):
        bright = 10 * np.log10(spec[region, high].sum() / target_spec[region, high].sum())
        spec_error += max(0.0, float(bright)) / len(REGIONS)
    tf, mf = 10 * np.log10(target_frames / target_frames.max()), 10 * np.log10(fr / fr.max())
    live = (tf > -30) | (mf > -30)
    decay = np.clip(mf - tf, -20, 20)
    # The first 20 ms, the strike itself, count double: a strike that lingers
    # sounds hollow, not creamy.
    weight = np.where(np.arange(len(fr)) < 10, 2.0, 1.0)
    decay_error = float((np.abs(decay) * weight)[live].sum() / weight[live].sum())
    # The decay as a correction at each recipe moment (frame centres 1, 3, 5... ms).
    centres = np.arange(len(fr)) * 2 + 1
    d_decay = -np.interp(TIMES, centres, np.where(live, decay, 0))
    return env_error, spec_error, decay_error, me, ms, d_decay


def spectrum_by_band(spec_db):
    """Per-region spectrum differences (centres) onto recipe cells (bands ×
    moments): the strike's for the strike's moments, the tail's after."""
    region = np.array([0 if t < REGIONS[1][0] else 1 for t in TIMES])
    return spec_db[region][:, :len(BANDS)].T


def fit(refs, length_ms, rounds=30):
    target_env = mean_envelope(refs)
    target_spec = mean_spectrum(refs)
    target_frames = mean_frames(refs)
    recipe = db(target_env).copy()
    best = None
    for r in range(rounds):
        env_error, spec_error, decay_error, me, ms, d_decay = errors(recipe, length_ms, target_env, target_spec, target_frames)
        # The tone and how fast it dies matter most.
        score = 0.5 * env_error + 2 * spec_error + decay_error
        if best is None or score < best[0]:
            best = (score, recipe.copy(), env_error, spec_error, decay_error)
        te = db(target_env)
        # Shape over time where it's audible...
        d_env = np.clip(te - me, -10, 10)
        d_env = np.where((te > -45) | (me > -45), d_env, 0)
        # ...and the overall balance between bands, which counts for more.
        ts = 10 * np.log10(target_spec / target_spec.max(axis=1, keepdims=True))
        d_spec = np.clip(spectrum_by_band(ts - ms), -10, 10)
        # Each band's own shape over time first; the last rounds settle the
        # tone and the decay alone (separable, so they don't fight).
        shape = 0.3 if r < rounds // 2 else 0.0
        recipe = recipe + shape * d_env + 0.5 * d_spec + 0.5 * np.clip(d_decay, -10, 10)[None, :]
        recipe = np.clip(recipe - recipe.max(), FLOOR, 0)
    return best[1], best[2], best[3], best[4]


def fit_width(refs, length_ms):
    """The low width whose fit sounds closest: tone and decay, which don't
    depend on the filters (the envelope error does)."""
    best = None
    for width in WIDTHS:
        WIDTH[0] = width
        recipe, env_error, spec_error, decay_error = fit(refs, length_ms)
        score = 2 * spec_error + 2 * decay_error
        if best is None or score < best[0]:
            best = (score, width, recipe, env_error, spec_error, decay_error)
    WIDTH[0] = best[1]
    return best[1:]


def tonality(x):
    """Spectral flatness (0 = pure tone, 1 = white noise) in 1-3 kHz, first 30 ms."""
    x = x[onset(x):][:int(0.03 * SR)]
    spec = np.abs(np.fft.rfft(x * np.hanning(len(x)), 8192)) ** 2
    f = np.fft.rfftfreq(8192, 1 / SR)
    band = spec[(f > 1000) & (f < 3000)] + 1e-20
    return float(np.exp(np.mean(np.log(band))) / np.mean(band))


def energy(x, ms=WINDOW_MS):
    x = x[onset(x):][:int(ms / 1000 * SR)]
    return float(np.mean(x ** 2)) if len(x) else 0.0


def peak_normalised_energy(recipe, length_ms):
    """Swift scales every take to the same peak; what energy is left."""
    takes = [synth(recipe, length_ms, s) for s in SEEDS]
    return float(np.mean([energy(x / np.max(np.abs(x))) for x in takes]))


if __name__ == '__main__':
    packs = json.loads(sys.argv[1])
    output = sys.argv[2] if len(sys.argv) > 2 else 'recipes.json'
    result = {}
    anchor = None  # The first board's letter keys set the loudness for all.
    for name, folder in packs.items():
        slices = pack_slices(folder)
        board, report = {}, {}
        for group in GROUPS:
            refs = group_refs(slices, group)
            lengths = [(len(s) - onset(s)) / SR * 1000 for s in refs]
            length = float(min(max(np.median(lengths), 30), 140))
            width, recipe, env_error, spec_error, decay_error = fit_width(refs, length)
            board[group] = {'db': np.round(recipe).astype(int).tolist(), 'length_ms': round(length), 'width': width,
                            'ref_energy': float(np.mean([energy(x) for x in refs])),
                            'synth_energy': peak_normalised_energy(np.round(recipe), length),
                            'env_error_db': round(env_error, 1), 'spectrum_error_db': round(spec_error, 1), 'decay_error_db': round(decay_error, 1),
                            'flatness_ref': round(float(np.median([tonality(x) for x in refs])), 2),
                            'flatness': round(float(np.median([tonality(synth(np.round(recipe), length, s)) for s in SEEDS])), 2)}
            report[group] = (width, board[group]['env_error_db'], board[group]['spectrum_error_db'], board[group]['decay_error_db'], board[group]['flatness_ref'], board[group]['flatness'])
        # Loudness: each group against the board's letters as the reference
        # has them, after Swift's peak scaling; each board's letters as loud
        # (in energy) as the first board's.
        text = board['text']
        if anchor is None:
            anchor = text['synth_energy']
        for group, e in board.items():
            relative = 10 * math.log10(e['ref_energy'] / text['ref_energy']) - 10 * math.log10(e['synth_energy'] / text['synth_energy'])
            level = 10 * math.log10(anchor / text['synth_energy'])
            # Real boards vary more than is pleasant to type on: keep 60 % of it.
            e['loudness_db'] = round(max(-6.0, min(4.0, 0.6 * relative + level)), 1)
        result[name] = board
        print(name, report, {g: e['loudness_db'] for g, e in board.items()}, flush=True)
    json.dump(result, open(output, 'w'))

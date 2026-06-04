#!/usr/bin/env python3
"""
SRT subtitle tool - three modes:

  1. GENERATE - Whisper transcribes the video and creates a perfectly-synced SRT.
  2. SYNC     - ffsubsync syncs an existing SRT, Whisper cross-checks the result.
  3. BATCH    - sync all video+SRT pairs in the current directory.

GPU is used automatically if CUDA (NVIDIA) or MPS (Apple Silicon) is detected.
openai-whisper and ffsubsync are installed automatically if missing.

Flags:
  --translate          Mode 2 outputs English regardless of source language
  --lang CODE          Source language hint (e.g. fr, id, es) — speeds up detection
  --lang-auto          Auto-detect language (default when --translate is used)
  --extract-all FILE   Non-interactive: extract all subtitle tracks and exit

Requirements:
  Python 3, ffmpeg in PATH.
"""
import os, sys, re, subprocess, struct, difflib, urllib.request, urllib.parse, json, glob
from statistics import median

# ---------- .env loader -------------------------------------------------------

def _load_env():
    """Parse KEY=value lines from .env in cwd or script directory."""
    import pathlib
    for candidate in [pathlib.Path('.env'),
                      pathlib.Path(__file__).resolve().parent / '.env']:
        try:
            for line in candidate.read_text().splitlines():
                line = line.strip()
                if not line or line.startswith('#') or '=' not in line:
                    continue
                k, _, v = line.partition('=')
                k = k.strip()
                v = v.strip().strip('"').strip("'")
                if k and k not in os.environ:
                    os.environ[k] = v
        except FileNotFoundError:
            pass

_load_env()

# =============================================================================
# TMDB API key — set here OR put  TMDB_API_KEY=your_key  in a .env file
# Get a free key at https://www.themoviedb.org/settings/api
TMDB_API_KEY = os.environ.get('TMDB_API_KEY', '')
# =============================================================================

# ---------- Path setup -------------------------------------------------------

def _extend_path():
    import site, pathlib
    candidates = []
    try:
        candidates.append(site.getusersitepackages())
    except Exception:
        pass
    home = str(pathlib.Path.home())
    candidates += glob.glob(
        os.path.join(home, '.local', 'lib', 'python*', 'site-packages')
    )
    for p in candidates:
        if p and os.path.isdir(p) and p not in sys.path:
            sys.path.insert(0, p)

_extend_path()

# ---------- ffsubsync finder -------------------------------------------------

def _find_ffsubsync():
    import shutil, pathlib
    found = shutil.which('ffsubsync')
    if found:
        return found
    local_bin = os.path.join(str(pathlib.Path.home()), '.local', 'bin', 'ffsubsync')
    if os.path.isfile(local_bin):
        return local_bin
    return None

# ---------- Optional dependency detection ------------------------------------

try:
    import whisper as _whisper
    WHISPER_AVAILABLE = True
except ImportError:
    _whisper = None
    WHISPER_AVAILABLE = False

FFSUBSYNC_AVAILABLE = _find_ffsubsync() is not None

TS_RE = re.compile(
    r'(\d{1,2}:\d{2}:\d{2}[,\.]\d{1,3})\s*-->\s*(\d{1,2}:\d{2}:\d{2}[,\.]\d{1,3})'
)
VIDEO_EXTS = ('.mp4','.mkv','.mov','.avi','.ts','.m2ts','.webm','.flv','.wmv','.mpg','.mpeg')

# ---------- Startup diagnostic -----------------------------------------------

def _check_deps():
    print("--- dependency check ---")
    try:
        import whisper as _w, inspect
        print(f"  whisper   : found at {os.path.dirname(inspect.getfile(_w))}")
    except ImportError:
        print("  whisper   : NOT found")
    exe = _find_ffsubsync()
    print(f"  ffsubsync : {'found at ' + exe if exe else 'NOT found'}")
    try:
        r    = subprocess.run(['ffmpeg', '-version'], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        line = r.stdout.decode(errors='ignore').splitlines()[0]
        print(f"  ffmpeg    : {line}")
    except FileNotFoundError:
        print("  ffmpeg    : NOT found - required!")
    local_paths = [p for p in sys.path if 'local' in p or 'site' in p]
    if local_paths:
        print("  sys.path (local/site entries):")
        for p in local_paths:
            print(f"    {p}")
    print("------------------------")

_check_deps()

# ---------- Tunable constants ------------------------------------------------

WHISPER_MODEL    = "large-v3-turbo"
WHISPER_LANGUAGE = "en"
WHISPER_TASK     = "transcribe"   # or "translate" (→ English output)

WHISPER_MODELS = {
    "1": ("tiny",           "~39 MB  - very fast, low accuracy"),
    "2": ("base",           "~74 MB  - fast, basic accuracy"),
    "3": ("small",          "~244 MB - good for simple audio"),
    "4": ("medium",         "~769 MB - better accuracy, slower"),
    "5": ("large-v3-turbo", "~809 MB - best speed/accuracy balance (recommended)"),
    "6": ("large-v3",       "~1.5 GB - highest accuracy, slowest"),
}

WHISPER_MODEL_SIZES = {
    "tiny": "39 MB", "base": "74 MB", "small": "244 MB",
    "medium": "769 MB", "large-v3-turbo": "809 MB", "large-v3": "1.5 GB",
}

WHISPER_PROMPT = (
    "Transcript with proper punctuation, capitalization, and grammar. "
    "Mark all sung lyrics and songs with ♪ symbols at the start and end. "
    "Use italics tags <i></i> for off-screen or narrator dialogue."
)

START_SKIP_S           = 0
ANALYZE_S              = 600      # 10 minutes of audio for alignment
MIN_WORD_LEN           = 4
OFFSET_AGREE_THRESHOLD = 1.5      # seconds - warn if ffsubsync and Whisper differ more than this

STOP_WORDS = {
    'the','and','you','that','was','for','are','with','his','they','this',
    'have','from','not','but','had','her','she','him','been','has','its',
    'who','did','get','may','now','can','our','out','all','yes','no',
    'what','just','will','your','when','them','than','then','some','into',
    'said','more','also','very','here','well','like','even','back','much',
}

MAX_OFFSET_S = 90.0
RESOLUTION_S = 0.1
RESAMPLE_HZ  = 100
SPEECH_LO    = 300
SPEECH_HI    = 3400
CHUNK_SIZE   = max(1, int(RESAMPLE_HZ * RESOLUTION_S))

_NOISE_RE = re.compile(
    r'\b(720p|1080p|2160p|4k|uhd|webrip|web|bluray|bdrip|dvdrip|hdtv|dl'
    r'|x264|x265|hevc|avc|h264|h265|aac|dts|ac3|nf|amzn|hulu|dsnp|atvp'
    r'|hmax|pcok|repack|proper|extended|theatrical|directors?cut|remux'
    r'|episode|episodes?)\b',
    re.IGNORECASE
)
_SXXEXX_RE     = re.compile(r'\bS(\d{1,2})E(\d{1,2})\b', re.IGNORECASE)
_SEASON_DIR_RE = re.compile(r'^[Ss]eason[\s._-]*\d+$')
_BRACKET_RE    = re.compile(r'^\s*\[[^\]]*\]\s*')   # leading [SubGroup] tags

_TEXT_SUB_CODECS  = {'subrip', 'srt', 'ass', 'ssa', 'mov_text',
                     'webvtt', 'microdvd', 'text', 'dvb_teletext'}
_IMAGE_SUB_CODECS = {'dvd_subtitle', 'hdmv_pgs_subtitle',
                     'dvb_subtitle', 'dvbsub', 'pgssub', 'xsub'}

# ---------- Auto-install helpers ---------------------------------------------

def _find_pip():
    for cmd in (['pip3'], ['pip']):
        try:
            if subprocess.run(cmd + ['--version'],
                              stdout=subprocess.DEVNULL,
                              stderr=subprocess.DEVNULL).returncode == 0:
                return cmd
        except FileNotFoundError:
            pass
    for py in [sys.executable, 'python3', 'python']:
        try:
            if subprocess.run([py, '-m', 'pip', '--version'],
                              stdout=subprocess.DEVNULL,
                              stderr=subprocess.DEVNULL).returncode == 0:
                return [py, '-m', 'pip']
        except FileNotFoundError:
            pass
    # Try bootstrapping pip via ensurepip
    try:
        if subprocess.run([sys.executable, '-m', 'ensurepip', '--upgrade'],
                          stdout=subprocess.DEVNULL,
                          stderr=subprocess.DEVNULL).returncode == 0:
            if subprocess.run([sys.executable, '-m', 'pip', '--version'],
                              stdout=subprocess.DEVNULL,
                              stderr=subprocess.DEVNULL).returncode == 0:
                return [sys.executable, '-m', 'pip']
    except Exception:
        pass
    # Last resort: apt-get
    print("  pip not found - attempting: sudo apt-get install python3-pip ...")
    try:
        if subprocess.run(['sudo', 'apt-get', 'install', '-y', 'python3-pip'],
                          timeout=120).returncode == 0:
            for cmd in (['pip3'], [sys.executable, '-m', 'pip']):
                try:
                    if subprocess.run(cmd + ['--version'],
                                      stdout=subprocess.DEVNULL,
                                      stderr=subprocess.DEVNULL).returncode == 0:
                        return cmd
                except FileNotFoundError:
                    pass
    except Exception:
        pass
    return None

def _pip_install(package):
    pip = _find_pip()
    if pip is None:
        print(f"  Cannot find pip. Try manually:  pip3 install {package}")
        return False
    for flags in [[], ['--user']]:
        if subprocess.run(pip + ['install'] + flags + [package]).returncode == 0:
            _extend_path()
            return True
    print("  Standard and --user installs failed.")
    if input("  Try --break-system-packages? [y/N]: ").strip().lower() == 'y':
        if subprocess.run(pip + ['install', '--break-system-packages',
                                 package]).returncode == 0:
            _extend_path()
            return True
    return False

def ensure_whisper():
    global _whisper, WHISPER_AVAILABLE
    if WHISPER_AVAILABLE:
        return True
    print("\nopenai-whisper is not installed.")
    if input("Install it now? [y/N]: ").strip().lower() != 'y':
        print("Skipping - will fall back to audio energy method.")
        return False
    print("Installing openai-whisper...")
    if not _pip_install('openai-whisper'):
        print("Installation failed.")
        return False
    import importlib
    importlib.invalidate_caches()
    try:
        import whisper as _w
        _whisper          = _w
        WHISPER_AVAILABLE = True
        print("Installed successfully.\n")
        return True
    except ImportError:
        print("Installed but import failed - try restarting the script.")
        return False

def ensure_ffsubsync():
    global FFSUBSYNC_AVAILABLE
    if FFSUBSYNC_AVAILABLE:
        return True
    print("\nffsubsync is not installed (recommended for syncing existing SRTs).")
    if input("Install it now? [y/N]: ").strip().lower() != 'y':
        return False
    print("Installing ffsubsync...")
    if not _pip_install('ffsubsync'):
        print("Installation failed.")
        return False
    import importlib
    importlib.invalidate_caches()
    if _find_ffsubsync():
        FFSUBSYNC_AVAILABLE = True
        print("ffsubsync installed successfully.")
        return True
    print("Installed but ffsubsync not found - try restarting the script.")
    return False

def ensure_easyocr():
    try:
        import easyocr  # noqa: F401
        return True
    except ImportError:
        pass
    print("\neasyocr not installed (needed to scan video frames for a title card).")
    if input("Install it now? (~200 MB package, ~170 MB model download on first use) [y/N]: ").strip().lower() != 'y':
        return False
    print("Installing easyocr...")
    if not _pip_install('easyocr'):
        print("Installation failed.")
        return False
    import importlib
    importlib.invalidate_caches()
    try:
        import easyocr  # noqa: F401
        return True
    except ImportError:
        print("Installed but import failed - try restarting the script.")
        return False

def ensure_ccextractor():
    """Return ccextractor command, or None if unavailable."""
    for cmd in ['ccextractor', 'ccextractorwin', 'ccx']:
        try:
            if subprocess.run([cmd, '--version'],
                              stdout=subprocess.DEVNULL,
                              stderr=subprocess.DEVNULL).returncode in (0, 1):
                return cmd
        except FileNotFoundError:
            pass
    print("\nccextractor not found (needed for CC and some DVD subtitles).")
    if input("Try to install via apt-get? [y/N]: ").strip().lower() != 'y':
        print("  Install manually: https://ccextractor.org")
        return None
    try:
        if subprocess.run(['sudo', 'apt-get', 'install', '-y', 'ccextractor'],
                          timeout=120).returncode == 0:
            return 'ccextractor'
    except Exception:
        pass
    print("  apt-get failed. Install manually: https://ccextractor.org")
    return None

def ensure_pgsreader():
    try:
        import pgsreader  # noqa: F401
        return True
    except ImportError:
        pass
    print("\npgsreader not installed (needed for Blu-ray PGS subtitles).")
    if input("Install it now? [y/N]: ").strip().lower() != 'y':
        return False
    if not _pip_install('pgsreader'):
        return False
    import importlib
    importlib.invalidate_caches()
    try:
        import pgsreader  # noqa: F401
        return True
    except ImportError:
        print("Installed but import failed - try restarting the script.")
        return False


def ensure_mkvtoolnix():
    """Return True if mkvmerge is available, offering to install if not."""
    import shutil, platform
    if shutil.which('mkvmerge'):
        return True
    print("\nmkvmerge not found — needed to embed subtitles into MKV files.")
    system = platform.system()
    if system == 'Darwin':
        if input("  Try to install via brew? [y/N]: ").strip().lower() == 'y':
            try:
                if subprocess.run(['brew', 'install', 'mkvtoolnix'],
                                  timeout=300).returncode == 0:
                    return bool(shutil.which('mkvmerge'))
            except Exception:
                pass
        print("  Install manually: brew install mkvtoolnix")
    else:
        if input("  Try to install via apt-get? [y/N]: ").strip().lower() == 'y':
            try:
                if subprocess.run(['sudo', 'apt-get', 'install', '-y', 'mkvtoolnix'],
                                  timeout=120).returncode == 0:
                    return bool(shutil.which('mkvmerge'))
            except Exception:
                pass
        print("  Install manually:")
        print("    Debian/Ubuntu : sudo apt install mkvtoolnix")
        print("    Arch          : sudo pacman -S mkvtoolnix-cli")
        print("    Other         : https://mkvtoolnix.download/")
    return False


def ensure_vobsub2srt():
    """Return True if vobsub2srt is available, offering to install if not."""
    import shutil
    if shutil.which('vobsub2srt'):
        return True
    print("\nvobsub2srt not found — needed for DVD VOB subtitle OCR to SRT.")
    if input("  Try to install via apt-get? [y/N]: ").strip().lower() == 'y':
        try:
            if subprocess.run(['sudo', 'apt-get', 'install', '-y', 'vobsub2srt'],
                              timeout=120).returncode == 0:
                return bool(shutil.which('vobsub2srt'))
        except Exception:
            pass
    print("  Install manually: sudo apt install vobsub2srt")
    print("  Alternative GUI : https://github.com/SubtitleEdit/subtitleedit")
    return False

# ---------- GPU detection ----------------------------------------------------

def get_device():
    try:
        import torch
        if torch.cuda.is_available():
            print(f"  GPU detected: {torch.cuda.get_device_name(0)} (CUDA)")
            return "cuda"
        if hasattr(torch.backends, 'mps') and torch.backends.mps.is_available():
            print("  GPU detected: Apple Silicon (MPS)")
            return "mps"
    except Exception:
        pass
    print("  No GPU detected - running on CPU.")
    return "cpu"

def load_whisper_model(model_name):
    device = get_device()
    size   = WHISPER_MODEL_SIZES.get(model_name, '?')
    print(f"  Loading Whisper '{model_name}' model "
          f"(first run downloads ~{size} to ~/.cache/whisper)...")
    try:
        return _whisper.load_model(model_name, device=device), device
    except Exception as e:
        if 'out of memory' in str(e).lower() and device != 'cpu':
            print("  GPU out of memory - clearing cache and retrying on CPU...")
            try:
                import torch
                torch.cuda.empty_cache()
                torch.cuda.synchronize()
            except Exception:
                pass
            return _whisper.load_model(model_name, device='cpu'), 'cpu'
        raise

# ---------- File listing / selection -----------------------------------------

def list_files(exts, label):
    exts  = (exts,) if isinstance(exts, str) else exts
    files = [f for f in sorted(os.listdir('.')) if f.lower().endswith(exts)]
    if not files:
        print(f"No {label} files found in current directory.")
    else:
        for i, f in enumerate(files, 1):
            print(f"{i}: {f}")
    return files

def pick_file(files, prompt, allow_skip=False):
    skip_hint = " or Enter to skip" if allow_skip else ""
    while True:
        choice = input(prompt + skip_hint + " (0 to cancel): ").strip()
        if choice == '0':
            return None
        if choice == "" and allow_skip:
            return ""
        if choice == "":
            for i, f in enumerate(files, 1):
                print(f"{i}: {f}")
            continue
        if choice.isdigit():
            idx = int(choice)
            if 1 <= idx <= len(files):
                return files[idx - 1]
            print("Invalid number.")
            continue
        if os.path.isfile(choice):
            return choice
        print("File not found.")

# ---------- SRT parsing / writing --------------------------------------------

def srt_to_seconds(t):
    h, m, rest = t.split(':')
    s, ms = rest.split(',')
    return int(h)*3600 + int(m)*60 + int(s) + int(ms)/1000.0

def seconds_to_srt(t):
    t  = max(0.0, t)
    h  = int(t) // 3600
    m  = (int(t) // 60) % 60
    s  = int(t) % 60
    ms = int(round((t - int(t)) * 1000))
    return f"{h:02d}:{m:02d}:{s:02d},{ms:03d}"

def _read_srt_text(path):
    """Read an SRT file, auto-detecting encoding and stripping BOM."""
    for enc in ('utf-8-sig', 'utf-16', 'cp1252', 'latin-1'):
        try:
            text = open(path, encoding=enc).read()
            # utf-16 files decoded correctly won't have lone surrogates
            return text
        except (UnicodeDecodeError, UnicodeError):
            continue
    return open(path, encoding='utf-8', errors='replace').read()


def _normalise_srt_ts(text):
    """Accept HH:MM:SS.mmm or H:MM:SS,mm etc. — normalise to HH:MM:SS,mmm."""
    def _fix(m):
        ts = m.group(0)
        ts = ts.replace('.', ',')
        ms_part = ts.rsplit(',', 1)[1]
        ts = ts.rsplit(',', 1)[0] + ',' + ms_part.ljust(3, '0')[:3]
        return ts
    return re.sub(r'\d{1,2}:\d{2}:\d{2}[,\.]\d{1,3}', _fix, text)


_HI_LINE_RE = re.compile(r'^\s*[\(\[].+[\)\]]\s*$')   # lines that are ONLY a bracketed description

def _is_hi_subtitle(path):
    """Return True if >25% of text lines look like HI sound descriptions."""
    entries = parse_srt_full(path, limit=80)
    if not entries:
        return False
    total = hi = 0
    for _, _, text in entries:
        for line in text.splitlines():
            line = line.strip()
            if not line:
                continue
            total += 1
            if _HI_LINE_RE.match(line):
                hi += 1
    return total > 0 and (hi / total) > 0.25


def _strip_hi_for_sync(src_path, dst_path):
    """Write a copy of src_path with description-only entries removed.
    Entries that mix dialogue with descriptions are kept (stripped to dialogue only).
    Returns True if any entries were removed/modified."""
    text   = _normalise_srt_ts(_read_srt_text(src_path))
    blocks = re.split(r'\n\s*\n', text.strip())
    out    = []
    changed = False
    for block in blocks:
        lines = block.strip().splitlines()
        ts_idx = next((i for i, l in enumerate(lines) if TS_RE.search(l)), None)
        if ts_idx is None:
            out.append(block)
            continue
        text_lines = [l for l in lines[ts_idx + 1:] if l.strip()]
        dialogue   = [l for l in text_lines if not _HI_LINE_RE.match(l)]
        if not text_lines:
            out.append(block)
        elif not dialogue:
            # entry is entirely sound descriptions — drop it
            changed = True
        else:
            if len(dialogue) < len(text_lines):
                changed = True
            out.append('\n'.join(lines[:ts_idx + 1] + dialogue))
    with open(dst_path, 'w', encoding='utf-8') as f:
        f.write('\n\n'.join(out))
    return changed

def parse_srt_full(path, limit=9999):
    entries = []
    try:
        text = _normalise_srt_ts(_read_srt_text(path))
    except Exception:
        return entries
    for block in re.split(r'\n\s*\n', text.strip()):
        lines = block.strip().splitlines()
        for i, line in enumerate(lines):
            m = TS_RE.search(line)
            if m:
                start = srt_to_seconds(m.group(1))
                end   = srt_to_seconds(m.group(2))
                body  = re.sub(r'<[^>]+>', '', ' '.join(lines[i+1:]).strip())
                entries.append((start, end, body))
                break
        if len(entries) >= limit:
            break
    return entries

def normalize_word(w):
    return re.sub(r"[^a-z0-9']", '', w.lower())

def srt_to_word_times(entries):
    result = []
    for start, _end, text in entries:
        for raw in text.split():
            w = normalize_word(raw)
            if len(w) >= MIN_WORD_LEN and w not in STOP_WORDS:
                result.append((w, start))
    return result

def shift_srt(inpath, outpath, offset):
    text = _normalise_srt_ts(_read_srt_text(inpath))
    with open(outpath, 'w', encoding='utf-8') as fout, \
         __import__('io').StringIO(text) as fin:
        for line in fin:
            m = TS_RE.search(line)
            if m:
                s = srt_to_seconds(m.group(1)) + offset
                e = srt_to_seconds(m.group(2)) + offset
                fout.write(f"{seconds_to_srt(s)} --> {seconds_to_srt(e)}\n")
            else:
                fout.write(line)

def parse_offset(s):
    try:
        return float(s)
    except Exception:
        return None

# ---------- Filename / show info parsing -------------------------------------

def extract_show_info(filepath, extra_paths=None):
    """
    Extract (show_name, SxxExx) by checking, in order:
      1. The video filename
      2. Any extra_paths (e.g. matching SRT filename)
      3. Directory path components (handles SxxExx in a folder name)
      4. Plex-style layout: .../Show Name/Season NN/file
      5. Immediate parent directory name as a last resort
    """
    show    = ''
    episode = ''

    def _parse_name(path):
        base = os.path.splitext(os.path.basename(path))[0]
        base = _BRACKET_RE.sub('', base)       # strip leading [SubGroup]
        base = re.sub(r'[._]', ' ', base)
        m = _SXXEXX_RE.search(base)
        if m:
            s = _NOISE_RE.sub('', base[:m.start()]).strip()
            return re.sub(r'\s+', ' ', s).strip(), m.group(0).upper()
        s = _NOISE_RE.sub('', base).strip()
        return re.sub(r'\s+', ' ', s).strip(), ''

    for path in [filepath] + (extra_paths or []):
        s, e = _parse_name(path)
        if not show and s:
            show = s
        if not episode and e:
            episode = e
        if show and episode:
            break

    if not show or not episode:
        parts = os.path.normpath(os.path.abspath(filepath)).split(os.sep)
        for part in reversed(parts[:-1]):
            part_clean = re.sub(r'[._]', ' ', part)
            m = _SXXEXX_RE.search(part_clean)
            if m:
                if not episode:
                    episode = m.group(0).upper()
                if not show:
                    s = _NOISE_RE.sub('', part_clean[:m.start()]).strip()
                    show = re.sub(r'\s+', ' ', s).strip()

        if not show:
            for i, part in enumerate(parts):
                if _SEASON_DIR_RE.match(part) and i > 0:
                    show = re.sub(r'[._]', ' ', parts[i - 1]).strip()
                    show = re.sub(r'\s+', ' ', show).strip()
                    break

        if not show:
            parent = os.path.basename(os.path.dirname(os.path.abspath(filepath)))
            if parent not in ('', '.') and not _SEASON_DIR_RE.match(parent):
                show = re.sub(r'[._]', ' ', parent).strip()
                show = re.sub(r'\s+', ' ', show).strip()

    return show, episode

# ---------- Text post-processing ---------------------------------------------

def postprocess_text(text):
    text = text.strip()
    if not text:
        return text
    # OCR misreads \u266a as $. Strip $ embedded inside words; replace remaining
    # $ (not before a digit) with \u266a so music-note lines are handled correctly.
    text = re.sub(r'(?<=[A-Za-z])\$(?=[A-Za-z])', '', text)
    text = re.sub(r'\$(?!\d)', '\u266a', text)
    music_rx  = re.compile(
        r'\[\s*(music|singing|song|humming|instrumental|melody)\s*\]',
        re.IGNORECASE
    )
    has_music = bool(music_rx.search(text)) or '\u266a' in text
    text      = music_rx.sub('\u266a', text)
    text      = re.sub(r'\[[^\]]{1,40}\]', '', text).strip()
    text      = re.sub(r'  +', ' ', text).strip()
    if has_music:
        core = re.sub(r'[\u266a]+', '', text).strip()
        text = f'\u266a {core} \u266a' if core else '\u266a'
    if text.startswith('\u266a'):
        after = text[1:].lstrip()
        if after and after[0].islower():
            text = '\u266a ' + after[0].upper() + after[1:]
    elif text and text[0].islower():
        text = text[0].upper() + text[1:]
    return text

# ---------- SRT vocabulary extraction ----------------------------------------

def extract_srt_vocab(srt_path, max_words=60):
    entries = parse_srt_full(srt_path)
    proper  = {}
    for _, _, text in entries:
        words = text.split()
        for i, raw in enumerate(words):
            w = re.sub(r"[^a-zA-Z']", '', raw)
            if not w:
                continue
            if i > 0 and w[0].isupper() and w.lower() not in STOP_WORDS:
                proper[w] = proper.get(w, 0) + 1
    return sorted(proper, key=lambda w: -proper[w])[:max_words]

def build_prompt(video_path, srt_path=None):
    show, episode = extract_show_info(video_path)
    prompt = WHISPER_PROMPT
    if show:
        prompt += f" This is '{show}'"
        prompt += f", {episode}." if episode else "."
    if srt_path and os.path.isfile(srt_path):
        vocab = extract_srt_vocab(srt_path)
        if vocab:
            prompt += f" Vocabulary: {', '.join(vocab)}."
    return prompt

# ---------- Mode 2: Generate SRT from scratch --------------------------------

def _detect_language(video_path, model):
    """Sample 30 s of audio and return (code, confidence, display_name)."""
    import numpy as np
    raw = subprocess.run([
        'ffmpeg', '-hide_banner', '-loglevel', 'error',
        '-i', video_path, '-t', '30',
        '-vn', '-ac', '1', '-ar', '16000', '-f', 'f32le', 'pipe:1'
    ], stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=60).stdout
    n = len(raw) // 4
    if n == 0:
        return None, None, None
    audio = np.frombuffer(raw, dtype=np.float32).copy()
    audio = _whisper.pad_or_trim(audio)
    n_mels = getattr(getattr(model, 'dims', None), 'n_mels', 80)
    mel    = _whisper.log_mel_spectrogram(audio, n_mels=n_mels).to(model.device)
    _, probs = model.detect_language(mel)
    code  = max(probs, key=probs.get)
    conf  = probs[code]
    names = getattr(_whisper.tokenizer, 'LANGUAGES', {})
    name  = names.get(code, code).title()
    return code, conf, name


def generate_srt(video_path, output_path, model_name, srt_path=None,
                 task='transcribe', language=None, _model=None):
    if _model is None:
        _model, _ = load_whisper_model(model_name)
    show, episode = extract_show_info(video_path)
    if show:
        print(f"  Detected show: '{show}'" + (f"  Episode: {episode}" if episode else ""))
    if srt_path:
        print(f"  Vocabulary seeded from: {os.path.basename(srt_path)}")
    if task == 'translate':
        hint = f" (source: {language})" if language else " (auto-detect source)"
        print(f"  Translating to English{hint} - lines will appear as recognised...")
    else:
        print("  Transcribing - lines will appear as they are recognised...")
    result = _model.transcribe(video_path,
                               initial_prompt=build_prompt(video_path, srt_path),
                               language=language,
                               task=task,
                               verbose=True)
    segs = result.get('segments', [])
    idx  = 0
    with open(output_path, 'w', encoding='utf-8') as f:
        for seg in segs:
            txt = postprocess_text(seg['text'])
            if not txt:
                continue
            idx += 1
            f.write(f"{idx}\n")
            f.write(f"{seconds_to_srt(seg['start'])} --> {seconds_to_srt(seg['end'])}\n")
            f.write(f"{txt}\n\n")
    return idx, output_path


def scan_title_card(video_path, start=20, duration=160, interval=5):
    """
    Extract frames from the video and OCR them to find on-screen episode title cards.
    Returns list of (text, frame_count, timestamp_seconds) sorted by frame count.
    """
    try:
        import easyocr
    except ImportError:
        print("  easyocr not available.")
        return []

    import tempfile, glob

    end = start + duration
    print(f"  Extracting frames ({start}s – {end}s, one every {interval}s)...")
    seen = {}  # lower-normalised key -> (original_case, count, first_timestamp)

    with tempfile.TemporaryDirectory() as tmpdir:
        frame_pattern = os.path.join(tmpdir, 'frame_%04d.png')
        r = subprocess.run([
            'ffmpeg', '-hide_banner', '-loglevel', 'error',
            '-ss', str(start), '-i', video_path,
            '-t', str(duration),
            '-vf', f'fps=1/{interval},scale=1280:-1',
            frame_pattern
        ], timeout=120)
        frames = sorted(glob.glob(os.path.join(tmpdir, 'frame_*.png')))
        if not frames:
            print("  No frames extracted.")
            return []

        print(f"  Running OCR on {len(frames)} frames"
              f" (first run downloads ~170 MB model)...")
        reader = easyocr.Reader(['en'], verbose=False)

        for frame_idx, frame_path in enumerate(frames):
            ts = start + frame_idx * interval
            try:
                results = reader.readtext(frame_path, detail=1, paragraph=False)
                frame_seen = set()
                for (_, text, conf) in results:
                    text = text.strip()
                    if conf < 0.4:
                        continue
                    words = text.split()
                    if not (2 <= len(words) <= 8) or not (4 <= len(text) <= 60):
                        continue
                    if re.search(r'[©®@]|\d{2}:\d{2}|www\.', text):
                        continue
                    key = re.sub(r'\s+', ' ', text).lower()
                    if key not in frame_seen:
                        frame_seen.add(key)
                        if key in seen:
                            seen[key] = (seen[key][0], seen[key][1] + 1, seen[key][2])
                        else:
                            seen[key] = (text, 1, ts)
            except Exception:
                continue

    return sorted(seen.values(), key=lambda x: -x[1])


def _timed_input(prompt, timeout=15):
    """Print prompt and wait for Enter; auto-continues after timeout seconds."""
    import select as _sel
    print(prompt, end='', flush=True)
    ready, _, _ = _sel.select([sys.stdin], [], [], timeout)
    if ready:
        sys.stdin.readline()
    else:
        print(f"  (timed out after {timeout}s)")


def _preview_frame(video_path, timestamp):
    """Extract the frame at timestamp and open it in the system image viewer."""
    import tempfile
    fd, png = tempfile.mkstemp(suffix='.png', prefix='cc_preview_')
    os.close(fd)
    try:
        subprocess.run([
            'ffmpeg', '-hide_banner', '-loglevel', 'error',
            '-ss', str(timestamp), '-i', video_path,
            '-frames:v', '1', '-y', png
        ], timeout=30, check=True)
        viewer = 'open' if sys.platform == 'darwin' else 'xdg-open'
        subprocess.Popen([viewer, png])
        _timed_input("  (Press Enter to continue, auto-closes in 15s...)", timeout=15)
    except Exception as e:
        print(f"  Preview failed: {e}")
    finally:
        try:
            os.unlink(png)
        except Exception:
            pass


def _sync_pass(video_path, whisper_out, final_out, ffsubsync_ok):
    """Run ffsubsync on whisper_out → final_out. Returns path of best result."""
    if not ffsubsync_ok:
        print("  ffsubsync not available, skipping timing pass.")
        return whisper_out
    ok, offset = sync_with_ffsubsync(video_path, whisper_out, final_out)
    if ok:
        if offset is not None:
            print(f"  Timing adjusted by {offset:+.3f} s")
        return final_out
    print("  ffsubsync timing pass failed - using Whisper output as-is.")
    return whisper_out


def generate_and_sync(video_path, model_name, srt_path=None, ffsubsync_ok=False):
    """Load model once, detect language, ask user, then transcribe/translate/both."""
    global WHISPER_TASK, WHISPER_LANGUAGE

    base  = os.path.splitext(video_path)[0]
    model, _ = load_whisper_model(model_name)

    # --- Language detection ---
    print("\n  Detecting language from first 30 seconds...")
    lang_code, conf, lang_name = _detect_language(video_path, model)
    if lang_code:
        print(f"  Detected: {lang_name} ({lang_code})  {conf*100:.0f}% confidence")
    else:
        print("  Language detection failed — defaulting to current setting.")
        lang_code = WHISPER_LANGUAGE

    is_english = lang_code in ('en', None)

    # --- Skip choice if --translate was passed explicitly ---
    if WHISPER_TASK == 'translate' and not is_english:
        task     = 'translate'
        src_lang = lang_code
        do_orig  = False
        do_en    = True
    elif is_english:
        task     = 'transcribe'
        src_lang = lang_code
        do_orig  = True
        do_en    = False
    else:
        # Non-English detected — ask what to generate
        print(f"\n  Source language: {lang_name}. What would you like?")
        print(f"    1: {lang_name} SRT        - transcribe in original language")
        print( "    2: English SRT       - translate to English")
        print(f"    3: Both              - {lang_name} + English SRT")
        print( "    0: Cancel")
        while True:
            ch = input("  Choose [2]: ").strip() or '2'
            if ch in ('0', '1', '2', '3'):
                break
            print("  Enter 0-3.")
        if ch == '0':
            return None
        do_orig = ch in ('1', '3')
        do_en   = ch in ('2', '3')
        src_lang = lang_code

    outputs = []

    # --- Original language pass ---
    if do_orig:
        suffix = f'-whisper-{src_lang}' if src_lang and src_lang != 'en' else '-whisper'
        w_out  = f"{base}{suffix}.srt"
        f_out  = f"{base}{suffix}-synced.srt"
        print(f"\nWhisper transcription → {os.path.basename(w_out)}")
        n, _ = generate_srt(video_path, w_out, model_name,
                             srt_path=srt_path, task='transcribe',
                             language=src_lang, _model=model)
        print(f"  {n} segments written.")
        print(f"\nffsubsync timing pass → {os.path.basename(f_out)}")
        outputs.append(_sync_pass(video_path, w_out, f_out, ffsubsync_ok))

    # --- English translation pass ---
    if do_en:
        w_out = f"{base}-whisper-en.srt"
        f_out = f"{base}-whisper-en-synced.srt"
        print(f"\nWhisper translation → English → {os.path.basename(w_out)}")
        n, _ = generate_srt(video_path, w_out, model_name,
                             srt_path=srt_path, task='translate',
                             language=src_lang, _model=model)
        print(f"  {n} segments written.")
        print(f"\nffsubsync timing pass → {os.path.basename(f_out)}")
        outputs.append(_sync_pass(video_path, w_out, f_out, ffsubsync_ok))

    return outputs[-1] if outputs else None

# ---------- ffsubsync --------------------------------------------------------

def sync_with_ffsubsync(video_path, srt_path, output_path):
    exe = _find_ffsubsync()
    if not exe:
        return False, None

    import tempfile

    # HI subtitles (hearing impaired) have many [sound] descriptions that
    # don't correspond to speech, wrecking VAD-based cross-correlation.
    # Sync on a dialogue-only copy; apply the resulting offset to the original.
    hi = _is_hi_subtitle(srt_path)
    if hi:
        print("  Detected HI (hearing-impaired) subtitle — stripping sound "
              "descriptions for sync pass, will reapply to original.")
        fd, stripped_path = tempfile.mkstemp(suffix='.srt')
        os.close(fd)
        _strip_hi_for_sync(srt_path, stripped_path)
        sync_src = stripped_path
    else:
        stripped_path = None
        sync_src = srt_path

    print("  Running ffsubsync (WebRTC VAD + FFT) - usually 20-30 seconds...")
    result = subprocess.run(
        [exe, video_path, '-i', sync_src, '-o', output_path],
        capture_output=True, text=True
    )

    if stripped_path:
        try:
            os.remove(stripped_path)
        except OSError:
            pass

    combined = result.stdout + result.stderr

    if result.returncode != 0 or not os.path.isfile(output_path):
        return False, None

    # Parse scale factor; if significant, apply it to correct framerate drift.
    # A plain offset fixes a constant gap; scaling fixes drift that grows over
    # time when the SRT was authored for a different framerate than the video.
    scale_m = re.search(r'framerate scale factor[:\s]+([\d.]+)', combined)
    if scale_m:
        scale = float(scale_m.group(1))
        if not 0.98 <= scale <= 1.02:
            src_fps = 'NTSC 23.976' if scale < 1.0 else 'PAL 25'
            vid_fps = 'PAL 25'      if scale < 1.0 else 'NTSC 23.976'
            drift   = abs(1.0 - scale) * 100
            print(f"  Framerate mismatch: SRT={src_fps}fps, video={vid_fps}fps "
                  f"(scale {scale:.4f}, ~{drift:.1f}% drift) — applying correction.")
            scaled = parse_srt_full(output_path)
            with open(output_path, 'w', encoding='utf-8') as _f:
                for _i, (_s, _e, _t) in enumerate(scaled, 1):
                    _f.write(f"{_i}\n{seconds_to_srt(_s * scale)} --> "
                             f"{seconds_to_srt(_e * scale)}\n{_t}\n\n")

    # If HI, we got a synced version of the stripped file; now shift the
    # original (with all descriptions) by the same offset instead.
    def first_ts(path):
        try:
            for line in _read_srt_text(path).splitlines():
                m = TS_RE.search(line)
                if m:
                    return srt_to_seconds(m.group(1))
        except Exception:
            pass
        return None

    t_orig   = first_ts(srt_path)
    t_synced = first_ts(output_path)
    offset   = (t_synced - t_orig) if (t_orig is not None and t_synced is not None) else None

    if hi and offset is not None:
        # Replace ffsubsync's output (stripped) with shifted original (full HI)
        shift_srt(srt_path, output_path, offset)

    return True, offset

# ---------- Whisper word alignment -------------------------------------------

def whisper_word_times(video_path, model_name, srt_path=None):
    import numpy as np
    model, device = load_whisper_model(model_name)
    print(f"  Extracting audio (first {ANALYZE_S//60} min)...")
    raw = subprocess.run([
        'ffmpeg', '-hide_banner',
        '-i', video_path,
        '-t', str(ANALYZE_S),
        '-vn', '-ac', '1', '-ar', '16000',
        '-f', 'f32le', 'pipe:1'
    ], stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=300).stdout
    n = len(raw) // 4
    if n == 0:
        raise RuntimeError("ffmpeg returned no audio.")
    audio = np.frombuffer(raw, dtype=np.float32).copy()
    print("  Transcribing...")
    result = model.transcribe(audio,
                              initial_prompt=build_prompt(video_path, srt_path),
                              language=WHISPER_LANGUAGE,
                              word_timestamps=True, verbose=False)
    words = []
    for seg in result.get('segments', []):
        for wd in seg.get('words', []):
            w = normalize_word(wd.get('word', ''))
            if len(w) >= MIN_WORD_LEN and w not in STOP_WORDS:
                words.append((w, wd['start']))
    return words

def compute_offset_whisper(srt_path, video_path, model_name):
    entries = parse_srt_full(srt_path)
    if not entries:
        return None, 0, 0, "No entries found in SRT."
    window_entries = [(s, e, t) for s, e, t in entries
                      if s <= ANALYZE_S + MAX_OFFSET_S]
    if not window_entries:
        print("  Warning: no SRT entries in analysis window - using first 100.")
        window_entries = entries[:100]
    srt_wt = srt_to_word_times(window_entries)
    if not srt_wt:
        return None, 0, 0, "No usable words in SRT window."
    print(f"  Analysis window: 0-{ANALYZE_S}s | {len(window_entries)} SRT cues")
    try:
        whi_wt = whisper_word_times(video_path, model_name, srt_path)
    except Exception as e:
        return None, 0, 0, f"Whisper failed: {e}"
    if not whi_wt:
        return None, 0, 0, "Whisper produced no output."
    print(f"  SRT: {len(srt_wt)} words  |  Whisper: {len(whi_wt)} words")
    print("  Aligning word sequences...")
    matcher = difflib.SequenceMatcher(
        None, [w for w, _ in srt_wt], [w for w, _ in whi_wt], autojunk=False
    )
    raw_offsets = []
    for i, j, n in matcher.get_matching_blocks():
        for k in range(n):
            raw_offsets.append(whi_wt[j+k][1] - srt_wt[i+k][1])
    if len(raw_offsets) < 5:
        return None, len(raw_offsets), 0, (
            f"Only {len(raw_offsets)} word matches. Is this SRT for this video?"
        )
    rough   = median(raw_offsets)
    cleaned = [o for o in raw_offsets if abs(o - rough) <= 2.0]
    if len(cleaned) < 5:
        cleaned = raw_offsets
    off    = median(cleaned)
    spread = max(cleaned) - min(cleaned)
    print(f"  Matches after outlier filter: {len(cleaned)}/{len(raw_offsets)}")
    return off, len(cleaned), spread, None

# ---------- Whisper cross-check of ffsubsync result --------------------------

def whisper_verify(srt_path, video_path, model_name, ffsubsync_offset):
    print("  Verifying with Whisper word alignment...")
    w_offset, n_matches, spread, err = compute_offset_whisper(
        srt_path, video_path, model_name
    )
    if err:
        return None, None, 0, 0, err
    agree = abs(w_offset - ffsubsync_offset) <= OFFSET_AGREE_THRESHOLD
    return agree, w_offset, n_matches, spread, None

# ---------- Fallback: speech-band energy cross-correlation ------------------

def extract_speech_energy(video_path):
    total = int(ANALYZE_S / RESOLUTION_S) + 1
    cmd   = [
        'ffmpeg', '-hide_banner',
        '-i', video_path,
        '-t', str(ANALYZE_S), '-vn', '-ac', '1',
        '-af', f'highpass=f={SPEECH_LO},lowpass=f={SPEECH_HI}',
        '-ar', str(RESAMPLE_HZ), '-f', 'f32le', 'pipe:1'
    ]
    try:
        r       = subprocess.run(cmd, stdout=subprocess.PIPE,
                                 stderr=subprocess.PIPE, timeout=300)
        raw     = r.stdout
        n       = len(raw) // 4
        if n == 0:
            return []
        samples = struct.unpack(f'<{n}f', raw)
        energy  = [0.0] * total
        for i in range(0, n, CHUNK_SIZE):
            seg = samples[i:i+CHUNK_SIZE]
            rms = (sum(x*x for x in seg) / len(seg)) ** 0.5
            bi  = i // CHUNK_SIZE
            if bi < total:
                energy[bi] = rms
        return energy
    except Exception as e:
        print(f"  Audio extraction error: {e}")
        return []

def compute_onsets(energy, lookback=2):
    onsets = [0.0] * len(energy)
    for i in range(lookback, len(energy)):
        d = energy[i] - energy[i - lookback]
        if d > 0:
            onsets[i] = d
    nz = sorted(o for o in onsets if o > 0)
    if nz:
        thr    = nz[len(nz) // 2]
        onsets = [o if o >= thr else 0.0 for o in onsets]
    return onsets

def crosscorr_offset(entries, energy):
    n_bins  = len(energy)
    max_lag = int(MAX_OFFSET_S / RESOLUTION_S)
    onsets  = compute_onsets(energy)
    seen, starts = set(), []
    for s, _e, _t in entries:
        si = max(0, int(s / RESOLUTION_S))
        if si not in seen:
            starts.append(si)
            seen.add(si)
    if not starts or not any(onsets):
        return 0.0, 0.0
    scores = [
        sum(onsets[i+lag] for i in starts if 0 <= i+lag < n_bins)
        for lag in range(-max_lag, max_lag + 1)
    ]
    best = max(range(len(scores)), key=lambda i: scores[i])
    mean = sum(scores) / len(scores)
    return (best - max_lag) * RESOLUTION_S, scores[best] / max(1e-9, mean)

def compute_offset_fallback(srt_path, video_path):
    entries = parse_srt_full(srt_path)
    if not entries:
        return None, None, "No entries in SRT."
    print("  Extracting speech-band audio energy...")
    energy = extract_speech_energy(video_path)
    if not energy or not any(energy):
        return None, None, "Could not extract audio from video."
    print("  Running onset cross-correlation...")
    offset, conf = crosscorr_offset(entries, energy)
    return offset, conf, None

# ---------- Core sync logic (used by Mode 2 and batch) ----------------------

def sync_single(video, src, out, ffsubsync_ok, whisper_ok, interactive=True):
    """
    Sync src SRT to video, writing result to out.
    ffsubsync runs first; Whisper independently verifies the offset.
    interactive=True prompts user on disagreement; False just warns and keeps ffsubsync.
    Returns True on success.
    """
    synced       = False
    final_offset = None

    # Primary: ffsubsync
    if ffsubsync_ok:
        ok, fs_offset = sync_with_ffsubsync(video, src, out)
        if ok:
            if fs_offset is not None:
                print(f"  ffsubsync offset : {fs_offset:+.3f} s")

            # Cross-check with Whisper
            if whisper_ok and fs_offset is not None:
                agree, w_offset, n_matches, spread, err = whisper_verify(
                    src, video, WHISPER_MODEL, fs_offset
                )
                if err:
                    print(f"  Whisper verify skipped: {err}")
                else:
                    quality = ("good" if spread < 2.0 else
                               "moderate" if spread < 5.0 else "low")
                    diff = abs(w_offset - fs_offset)
                    print(f"  Whisper offset   : {w_offset:+.3f} s "
                          f"({n_matches} words, spread {spread:.1f}s, {quality})")
                    if agree:
                        print(f"  Agreement        : YES (differ by {diff:.2f}s) "
                              f"- using ffsubsync result.")
                    else:
                        print(f"  Agreement        : NO  (differ by {diff:.2f}s, "
                              f"threshold {OFFSET_AGREE_THRESHOLD}s)")
                        if interactive:
                            print(f"  [f] Use ffsubsync ({fs_offset:+.3f}s)")
                            print(f"  [w] Use Whisper   ({w_offset:+.3f}s)")
                            print(f"  [e] Enter offset manually")
                            while True:
                                choice = input("  Choose [f/w/e]: ").strip().lower()
                                if choice == 'f':
                                    print("  Using ffsubsync offset.")
                                    break
                                elif choice == 'w':
                                    print("  Re-applying Whisper offset...")
                                    shift_srt(src, out, w_offset)
                                    final_offset = w_offset
                                    break
                                elif choice == 'e':
                                    while True:
                                        resp   = input("  Enter offset in seconds: ").strip()
                                        manual = parse_offset(resp)
                                        if manual is not None:
                                            shift_srt(src, out, manual)
                                            final_offset = manual
                                            break
                                        print("  Invalid number.")
                                    break
                        else:
                            print(f"  WARNING: methods disagree by {diff:.2f}s. "
                                  f"Keeping ffsubsync - review manually.")

            synced       = True
            final_offset = final_offset or fs_offset
        else:
            print("  ffsubsync failed - falling back to Whisper...")

    # Fallback 1: Whisper word alignment
    if not synced and whisper_ok:
        offset, n_matches, spread, err = compute_offset_whisper(src, video, WHISPER_MODEL)
        if not err:
            quality = ("good" if spread < 2.0 else
                       "moderate" if spread < 5.0 else "low")
            print(f"  Whisper offset: {offset:+.3f} s "
                  f"({n_matches} matches, spread {spread:.1f}s, {quality})")
            shift_srt(src, out, offset)
            final_offset = offset
            synced       = True
        else:
            print(f"  Whisper failed: {err}")
            print("  Trying audio energy cross-correlation...")

    # Fallback 2: energy cross-correlation
    if not synced:
        offset, conf, err = compute_offset_fallback(src, video)
        if not err:
            q = "LOW" if conf < 1.5 else "moderate" if conf < 2.5 else "good"
            print(f"  Energy offset: {offset:+.3f} s (confidence {conf:.2f}x, {q})")
            shift_srt(src, out, offset)
            final_offset = offset
            synced       = True
        else:
            print(f"  All methods failed: {err}")

    if synced and final_offset is not None:
        print(f"  Final offset: {final_offset:+.3f} s")

    return synced

# ---------- Batch helpers ----------------------------------------------------

def find_srt_for_video(video_path, srt_files):
    _, ep    = extract_show_info(video_path)
    ep_lower = ep.lower() if ep else None
    base     = os.path.splitext(os.path.basename(video_path))[0]

    candidates = [f for f in srt_files
                  if not f.lower().endswith('-synced.srt')
                  and not f.lower().endswith('-whisper.srt')]

    if ep_lower:
        ep_matches = [f for f in candidates if ep_lower in f.lower()]
        if ep_matches:
            return sorted(ep_matches, key=len)[0]

    exact = base + '.srt'
    if exact in candidates:
        return exact
    return None

def batch_sync(ffsubsync_ok, whisper_ok):
    video_files = [f for f in sorted(os.listdir('.'))
                   if f.lower().endswith(VIDEO_EXTS)]
    srt_files   = [f for f in sorted(os.listdir('.'))
                   if f.lower().endswith('.srt')]

    if not video_files:
        print("No video files found.")
        return
    if not srt_files:
        print("No SRT files found.")
        return

    pairs, unmatched = [], []
    for vf in video_files:
        sf = find_srt_for_video(vf, srt_files)
        if sf:
            out = os.path.splitext(sf)[0] + '-synced.srt'
            if os.path.isfile(out):
                print(f"  Skipping {vf} - {os.path.basename(out)} already exists.")
            else:
                pairs.append((vf, sf, out))
        else:
            unmatched.append(vf)

    if not pairs:
        print("No unprocessed pairs found.")
        if unmatched:
            print("Videos with no matching SRT:")
            for v in unmatched:
                print(f"  {v}")
        return

    print(f"\nFound {len(pairs)} pair(s) to process:")
    for vf, sf, out in pairs:
        print(f"  {vf}  +  {sf}  ->  {os.path.basename(out)}")
    if unmatched:
        print(f"\n{len(unmatched)} video(s) with no matching SRT (skipped):")
        for v in unmatched:
            print(f"  {v}")

    if input("\nProceed? [Y/n]: ").strip().lower() not in ('', 'y'):
        print("Cancelled.")
        return

    ok_count, fail_count, failed = 0, 0, []
    for vf, sf, out in pairs:
        print(f"\n{'='*60}")
        print(f"  Video : {vf}")
        print(f"  SRT   : {sf}")
        print(f"  Output: {os.path.basename(out)}")
        if sync_single(vf, sf, out, ffsubsync_ok, whisper_ok, interactive=False):
            ok_count += 1
        else:
            fail_count += 1
            failed.append(vf)

    print(f"\n{'='*60}")
    print(f"Batch complete: {ok_count} synced, {fail_count} failed.")
    if failed:
        print("Run Mode 2 manually on these:")
        for v in failed:
            print(f"  {v}")

# ---------- TMDB episode lookup + rename -------------------------------------

def tmdb_get(path, params, api_key):
    params = dict(params)  # don't mutate caller's dict
    params['api_key'] = api_key
    url = f"https://api.themoviedb.org/3{path}?{urllib.parse.urlencode(params)}"
    req = urllib.request.Request(url, headers={'Accept-Encoding': 'gzip, deflate'})
    try:
        with urllib.request.urlopen(req, timeout=10) as r:
            raw = r.read()
        if raw[:2] == b'\x1f\x8b':
            import gzip
            raw = gzip.decompress(raw)
        return json.loads(raw.decode('utf-8'))
    except Exception as e:
        print(f"  TMDB error: {e}")
        return None

def _get_tmdb_key():
    key = TMDB_API_KEY.strip()
    if not key:
        print("  Get a free key at https://www.themoviedb.org/settings/api")
        key = input("  Enter TMDB API key: ").strip()
    if not key:
        print("  No key - skipping.")
        return None
    return key


def tmdb_pick_show(show_name, key):
    """Search TMDB for show_name and let the user pick. Returns (show_id, canonical) or (None, None)."""
    data = tmdb_get('/search/tv', {'query': show_name, 'page': 1}, key)
    if not data or not data.get('results'):
        print("  No results found.")
        return None, None
    results = data['results'][:6]
    if len(results) > 1:
        print("  Multiple results:")
        for i, r in enumerate(results, 1):
            year = r.get('first_air_date', '')[:4]
            print(f"    {i}: {r['name']} ({year})")
        choice = input("  Choose [1]: ").strip()
        idx = (int(choice)-1) if choice.isdigit() and 1 <= int(choice) <= len(results) else 0
    else:
        idx = 0
    return results[idx]['id'], results[idx]['name']


def tmdb_find_episode_by_title(show_id, ep_title, key):
    """
    Scan every season of show_id on TMDB looking for an episode whose title
    matches ep_title (case-insensitive). Returns (season, episode_number) or (None, None).
    """
    show_data = tmdb_get(f'/tv/{show_id}', {}, key)
    if not show_data:
        return None, None
    n_seasons   = show_data.get('number_of_seasons', 0)
    target      = ep_title.strip().lower()
    for s in range(1, n_seasons + 1):
        season_data = tmdb_get(f'/tv/{show_id}/season/{s}', {}, key)
        if not season_data:
            continue
        for ep in season_data.get('episodes', []):
            if ep.get('name', '').strip().lower() == target:
                return s, ep['episode_number']
    return None, None


def safe_filename(s):
    return re.sub(r'[<>:"/\\|?*]', '', s).strip()

def find_matching_srt(video_path):
    base    = os.path.splitext(video_path)[0]
    dirpath = os.path.dirname(video_path) or '.'
    for suffix in ('', '-synced', '-offset', '-whisper'):
        c = base + suffix + '.srt'
        if os.path.isfile(c):
            return c
    _, ep_code = extract_show_info(video_path)
    if ep_code:
        for f in os.listdir(dirpath):
            if f.lower().endswith('.srt') and ep_code.lower() in f.lower():
                return os.path.join(dirpath, f)
    return None

def do_rename(filepath, new_base):
    ext      = os.path.splitext(filepath)[1]
    dirpath  = os.path.dirname(filepath) or '.'
    new_path = os.path.join(dirpath, new_base + ext)
    if os.path.abspath(filepath) == os.path.abspath(new_path):
        print("  Already named correctly.")
        return new_path
    try:
        os.rename(filepath, new_path)
        print(f"  -> {os.path.basename(new_path)}")
        return new_path
    except Exception as e:
        print(f"  Rename failed: {e}")
        return filepath

def _tmdb_rename(video_path, show_name, episode_code, srt_path):
    """Core TMDB lookup + rename. show_name / episode_code may be empty strings."""
    if not episode_code:
        print("  No SxxExx found in filename, SRT, or directory path - skipping.")
        return
    m = re.match(r'S(\d+)E(\d+)', episode_code, re.IGNORECASE)
    if not m:
        return
    season, episode = int(m.group(1)), int(m.group(2))
    if not show_name:
        show_name = input("  Could not detect show name. Enter show name: ").strip()
        if not show_name:
            print("  No show name - skipping.")
            return
    key = _get_tmdb_key()
    if not key:
        return
    print(f"  Searching TMDB for '{show_name}'...")
    show_id, canonical = tmdb_pick_show(show_name, key)
    if not show_id:
        return
    ep_data  = tmdb_get(f'/tv/{show_id}/season/{season}/episode/{episode}', {}, key)
    if ep_data and 'name' in ep_data:
        new_base = (f"{safe_filename(canonical)} - "
                    f"S{season:02d}E{episode:02d} - {safe_filename(ep_data['name'])}")
    else:
        print("  Episode title not found - using show name + SxxExx only.")
        new_base = f"{safe_filename(canonical)} - S{season:02d}E{episode:02d}"
    _confirm_and_rename(video_path, new_base, srt_path)


def _confirm_and_rename(video_path, new_base, srt_path):
    ext = os.path.splitext(video_path)[1]
    print(f"\n  New name: {new_base}{ext}")
    if srt_path:
        print(f"  SRT    : {new_base}.srt")
    if input("  Rename? [Y/n]: ").strip().lower() not in ('', 'y'):
        print("  Skipped.")
        return
    do_rename(video_path, new_base)
    if srt_path:
        do_rename(srt_path, new_base)


def offer_rename(video_path):
    if input("\nLook up episode title on TMDB and rename files? [y/N]: ").strip().lower() != 'y':
        return
    srt_path           = find_matching_srt(video_path)
    extra              = [srt_path] if srt_path else []
    show_name, ep_code = extract_show_info(video_path, extra_paths=extra)
    print(f"  Show   : {show_name or '(not detected)'}")
    print(f"  Episode: {ep_code   or '(not detected)'}")
    _tmdb_rename(video_path, show_name, ep_code, srt_path)


def rename_mode(video_path, ocr_ok, _method=None):
    srt_path           = find_matching_srt(video_path)
    extra              = [srt_path] if srt_path else []
    show_name, ep_code = extract_show_info(video_path, extra_paths=extra)

    print(f"\n  Show   : {show_name or '(not detected)'}")
    print(f"  Episode: {ep_code   or '(not detected)'}")

    if _method is None:
        print("\n  How to find the episode title?")
        print("    1: TMDB lookup    - search by show name + SxxExx  [default]")
        if ocr_ok:
            print("    2: Scan video     - OCR the first 3 min for a title card")
        choice = input("  Choose [1]: ").strip() or '1'
    else:
        choice = _method

    if choice == '2' and ocr_ok:
        candidates = scan_title_card(video_path)
        if not candidates:
            print("  No title candidates found - falling back to TMDB.")
        else:
            top = candidates[:20]
            print(f"\n  Candidates (sorted by how many frames they appeared in):")
            for i, (text, count, _ts) in enumerate(top, 1):
                print(f"    {i}: {text}  ({count} frame{'s' if count != 1 else ''})")
            print("\n  Enter a number to select, p<N> to preview that frame, "
                  "or Enter to fall back to TMDB.")
            ep_title = None
            while True:
                sel = input("  > ").strip()
                if not sel:
                    break
                pm = re.match(r'^[pP](\d+)$', sel)
                if pm:
                    pidx = int(pm.group(1))
                    if 1 <= pidx <= len(top):
                        _preview_frame(video_path, top[pidx - 1][2])
                    else:
                        print(f"  Choose 1–{len(top)}.")
                    continue
                if sel.isdigit() and 1 <= int(sel) <= len(top):
                    ep_title = top[int(sel) - 1][0]
                    break
                print(f"  Enter a number (1–{len(top)}), p<N> to preview, or Enter to skip.")

            if ep_title:
                if not show_name:
                    show_name = input("  Enter show name: ").strip()
                if not show_name:
                    print("  No show name - skipping.")
                    return
                key = _get_tmdb_key()
                if not key:
                    return
                print(f"  Searching TMDB for '{show_name}' / episode '{ep_title}'...")
                show_id, canonical = tmdb_pick_show(show_name, key)
                if show_id:
                    season, ep_num = tmdb_find_episode_by_title(show_id, ep_title, key)
                    if season and ep_num:
                        new_base = (f"{safe_filename(canonical)} - "
                                    f"S{season:02d}E{ep_num:02d} - {safe_filename(ep_title)}")
                        _confirm_and_rename(video_path, new_base, srt_path)
                        return
                    print("  Episode title not found on TMDB.")
                    if ep_code:
                        m = re.match(r'S(\d+)E(\d+)', ep_code, re.IGNORECASE)
                        if m:
                            season, ep_num = int(m.group(1)), int(m.group(2))
                            new_base = (f"{safe_filename(canonical or show_name)} - "
                                        f"S{season:02d}E{ep_num:02d} - {safe_filename(ep_title)}")
                            _confirm_and_rename(video_path, new_base, srt_path)
                            return
                    print("  No episode code available either - skipping.")
                return

    # Default: TMDB lookup
    _tmdb_rename(video_path, show_name, ep_code, srt_path)


def _rename_one_batch(video_path, srt_path, show_id, canonical, key, auto):
    """Rename one file within a batch. Returns True if renamed/confirmed, False if skipped."""
    extra   = [srt_path] if srt_path else []
    _, ep_code = extract_show_info(video_path, extra_paths=extra)
    if not ep_code:
        print(f"  {os.path.basename(video_path)}: no SxxExx found - skipping.")
        return False
    m = re.match(r'S(\d+)E(\d+)', ep_code, re.IGNORECASE)
    if not m:
        print(f"  {os.path.basename(video_path)}: cannot parse {ep_code} - skipping.")
        return False
    season, ep_num = int(m.group(1)), int(m.group(2))
    ep_data = tmdb_get(f'/tv/{show_id}/season/{season}/episode/{ep_num}', {}, key)
    if ep_data and 'name' in ep_data:
        new_base = (f"{safe_filename(canonical)} - "
                    f"S{season:02d}E{ep_num:02d} - {safe_filename(ep_data['name'])}")
    else:
        print(f"  {os.path.basename(video_path)}: episode title not found - using SxxExx only.")
        new_base = f"{safe_filename(canonical)} - S{season:02d}E{ep_num:02d}"
    ext = os.path.splitext(video_path)[1]
    print(f"  {os.path.basename(video_path)}")
    print(f"    -> {new_base}{ext}")
    if auto:
        do_rename(video_path, new_base)
        if srt_path:
            do_rename(srt_path, new_base)
    else:
        if input("  Rename? [Y/n]: ").strip().lower() in ('', 'y'):
            do_rename(video_path, new_base)
            if srt_path:
                do_rename(srt_path, new_base)
        else:
            print("  Skipped.")
    return True


def _next_file_prompt(vid_files, idx, allow_auto=False):
    """
    After processing vid_files[idx], ask what to do next.
    Returns (next_index, go_auto). next_index is None to stop.
    Enter = next file, 0 = stop, a = auto rest (if allow_auto), N = jump.
    """
    next_idx = idx + 1
    if next_idx >= len(vid_files):
        print("  No more files.")
        return None, False
    print(f"\n  Next: {os.path.basename(vid_files[next_idx])}")
    auto_hint = "  [a] auto rest  |  " if allow_auto else "  "
    print(f"{auto_hint}[Enter] continue  |  [0] stop  |  [1-{len(vid_files)}] jump to file")
    ans = input("  > ").strip().lower()
    if ans == '0':
        return None, False
    if ans == 'a' and allow_auto:
        return next_idx, True
    if ans == '':
        return next_idx, False
    if ans.isdigit() and 1 <= int(ans) <= len(vid_files):
        return int(ans) - 1, False
    return next_idx, False


def rename_tmdb_loop():
    print("\n  Video files in current directory:")
    vid_files = list_files(VIDEO_EXTS, "video")
    if not vid_files:
        print("  No video files found.")
        return

    video = pick_file(vid_files, "  Choose starting file")
    if not video or not os.path.isfile(video):
        print("  No valid video selected.")
        return

    srt0      = find_matching_srt(video)
    extra0    = [srt0] if srt0 else []
    show_name, _ = extract_show_info(video, extra_paths=extra0)
    if not show_name:
        show_name = input("  Could not detect show name. Enter show name: ").strip()
        if not show_name:
            return

    key = _get_tmdb_key()
    if not key:
        return

    print(f"  Searching TMDB for '{show_name}'...")
    show_id, canonical = tmdb_pick_show(show_name, key)
    if not show_id:
        return
    print(f"  Show: {canonical}\n")

    idx  = vid_files.index(video) if video in vid_files else 0
    auto = False
    while True:
        vf  = vid_files[idx]
        srt = find_matching_srt(vf)
        _rename_one_batch(vf, srt, show_id, canonical, key, auto=auto)
        if auto:
            idx += 1
            if idx >= len(vid_files):
                print("  No more files.")
                break
        else:
            idx, auto = _next_file_prompt(vid_files, idx, allow_auto=True)
            if idx is None:
                break


def rename_scan_loop(ocr_ok):
    print("\n  Video files in current directory:")
    vid_files = list_files(VIDEO_EXTS, "video")
    if not vid_files:
        print("  No video files found.")
        return

    video = pick_file(vid_files, "  Choose starting file")
    if not video or not os.path.isfile(video):
        print("  No valid video selected.")
        return

    idx = vid_files.index(video) if video in vid_files else 0
    while True:
        rename_mode(vid_files[idx], ocr_ok, _method='2')
        idx, _ = _next_file_prompt(vid_files, idx)
        if idx is None:
            break


def rename_menu(ocr_ok):
    while True:
        print("\n  RENAME")
        print("    1: TMDB lookup  [default]")
        if ocr_ok:
            print("    2: Scan video for title card")
        print("    0: Back to main menu")
        valid = ('0', '1', '2') if ocr_ok else ('0', '1')
        while True:
            choice = input("  Choose [1]: ").strip() or '1'
            if choice in valid:
                break
            print(f"  Please enter {'0, 1 or 2' if ocr_ok else '0 or 1'}.")

        if choice == '0':
            break
        elif choice == '1':
            rename_tmdb_loop()
        elif choice == '2':
            rename_scan_loop(ocr_ok)

# ---------- Subtitle extraction ----------------------------------------------

def probe_subtitle_streams(video_path):
    """Return list of subtitle stream dicts from ffprobe."""
    try:
        r = subprocess.run([
            'ffprobe', '-v', 'quiet', '-print_format', 'json',
            '-show_streams', '-select_streams', 's', video_path
        ], capture_output=True, text=True, timeout=30)
        return json.loads(r.stdout).get('streams', [])
    except Exception:
        return []


def _sub_out_path(video_path, lang=''):
    base = os.path.splitext(video_path)[0]
    return f"{base}.{lang}.srt" if lang else f"{base}.srt"


def _extract_text_track(video_path, stream_index, out_path):
    r = subprocess.run([
        'ffmpeg', '-hide_banner', '-loglevel', 'error',
        '-i', video_path, '-map', f'0:{stream_index}',
        '-c:s', 'srt', '-y', out_path
    ], timeout=300)
    return r.returncode == 0 and os.path.isfile(out_path)


def _extract_cc(video_path, out_path, cce_cmd):
    print("  Running ccextractor...")
    r = subprocess.run([cce_cmd, video_path, '-o', out_path], timeout=600)
    return r.returncode == 0 and os.path.isfile(out_path)


def _extract_pgs(video_path, stream_index, out_path):
    """Extract Blu-ray PGS subtitle track → SRT via pgsreader + easyocr."""
    try:
        import easyocr
        from pgsreader import PGSReader
        import numpy as np
        from PIL import Image as _PILImage
    except ImportError as e:
        print(f"  Missing dependency: {e}")
        return False

    import tempfile
    fd, sup_path = tempfile.mkstemp(suffix='.sup')
    os.close(fd)
    try:
        print("  Extracting PGS stream...")
        r = subprocess.run([
            'ffmpeg', '-hide_banner', '-loglevel', 'error',
            '-i', video_path, '-map', f'0:{stream_index}',
            '-c:s', 'copy', '-y', sup_path
        ], timeout=300)
        if r.returncode != 0:
            print("  ffmpeg extraction failed.")
            return False

        print("  Reading PGS display sets...")
        pgs     = PGSReader(sup_path)
        reader  = easyocr.Reader(['en'], verbose=False)
        entries = []
        pending = None

        for ds in pgs.displaySets:
            ts_s = ds.pcs.presentation_timestamp / 90000.0
            if ds.has_image:
                img     = ds.to_image().convert('RGB')
                results = reader.readtext(np.array(img), detail=0, paragraph=True)
                text    = ' '.join(results).strip()
                if pending:
                    entries.append(pending)
                pending = [ts_s, None, text] if text else None
            else:
                if pending:
                    pending[1] = ts_s
                    entries.append(pending)
                    pending = None

        if pending:
            pending[1] = pending[0] + 3.0
            entries.append(pending)

        print(f"  Writing {len(entries)} subtitle entries...")
        with open(out_path, 'w', encoding='utf-8') as f:
            for i, (start, end, text) in enumerate(entries, 1):
                f.write(f"{i}\n")
                f.write(f"{seconds_to_srt(start)} --> {seconds_to_srt(end)}\n")
                f.write(f"{text}\n\n")
        return True
    finally:
        try:
            os.unlink(sup_path)
        except Exception:
            pass


def _extract_vobsub(video_path, stream_index, out_path):
    """Extract DVD VOB subtitle track → SRT via vobsub2srt."""
    if not ensure_vobsub2srt():
        return False
    import tempfile, shutil
    with tempfile.TemporaryDirectory() as tmpdir:
        sub_base = os.path.join(tmpdir, 'subs')
        r = subprocess.run([
            'ffmpeg', '-hide_banner', '-loglevel', 'error',
            '-i', video_path, '-map', f'0:{stream_index}',
            '-c:s', 'copy', '-y', sub_base + '.sub'
        ], timeout=300)
        if r.returncode != 0:
            print("  ffmpeg extraction failed.")
            return False
        r2 = subprocess.run(['vobsub2srt', sub_base], timeout=300)
        if r2.returncode == 0 and os.path.isfile(sub_base + '.srt'):
            shutil.copy(sub_base + '.srt', out_path)
            return True
    print("  vobsub2srt conversion failed.")
    return False


def extract_subs_mode():
    print("\n  Video files in current directory:")
    vid_files = list_files(VIDEO_EXTS, "video")
    if vid_files:
        video = pick_file(vid_files, "  Choose video by number or filename")
    else:
        video = input("  Enter path to video file (0 to cancel): ").strip()
        if video == '0':
            return
    if not video or not os.path.isfile(video):
        print("  No valid video selected.")
        return

    video = _offer_mp4_remux(video)
    streams = probe_subtitle_streams(video)

    # Build menu: numbered subtitle tracks + CC option
    options = []
    if streams:
        print("\n  Subtitle tracks found:")
        for s in streams:
            codec = s.get('codec_name', 'unknown')
            idx   = s.get('index', '?')
            lang  = s.get('tags', {}).get('language', '')
            title = s.get('tags', {}).get('title', '')
            label = codec
            if lang:  label += f" [{lang}]"
            if title: label += f" — {title}"
            if codec in _TEXT_SUB_CODECS:
                label += "  (text, instant)"
            elif codec in _IMAGE_SUB_CODECS:
                label += "  (image, needs OCR)"
            print(f"    {len(options)+1}: {label}")
            options.append(('track', s))
    else:
        print("\n  No subtitle tracks found in file.")

    print(f"    {len(options)+1}: Closed captions from video stream (ccextractor)")
    options.append(('cc', None))
    print("    0: Cancel")

    while True:
        sel = input("  Choose: ").strip()
        if sel == '0':
            return
        if sel.isdigit() and 1 <= int(sel) <= len(options):
            break
        print(f"  Enter 1-{len(options)} or 0.")

    kind, stream = options[int(sel) - 1]
    base         = os.path.splitext(video)[0]

    if kind == 'cc':
        cce = ensure_ccextractor()
        if not cce:
            return
        out = _sub_out_path(video, 'cc')
        if _extract_cc(video, out, cce):
            print(f"  Done: {os.path.basename(out)}")
        else:
            print("  ccextractor found no CC in this file.")
        return

    codec      = stream.get('codec_name', '')
    stream_idx = stream.get('index')
    lang       = stream.get('tags', {}).get('language', '')
    out        = _sub_out_path(video, lang)

    if codec in _TEXT_SUB_CODECS:
        print(f"  Extracting text track {stream_idx} → {os.path.basename(out)} ...")
        if _extract_text_track(video, stream_idx, out):
            print(f"  Done: {os.path.basename(out)}")
        else:
            print("  Extraction failed.")

    elif codec in _IMAGE_SUB_CODECS:
        print(f"\n  '{codec}' is an image-based subtitle format.")
        print("    1: Native format  - extract as .sup / .sub (perfect quality, instant)  [default]")
        print("    2: OCR to SRT     - read text via OCR (editable, some quality loss)")
        fmt = input("  Choose [1]: ").strip() or '1'

        if fmt != '2':
            # Native extraction — no OCR, perfect quality
            if codec in {'hdmv_pgs_subtitle', 'pgssub'}:
                native_out = base + (f'.{lang}' if lang else '') + '.sup'
            else:
                native_out = base + (f'.{lang}' if lang else '') + '.sub'
            print(f"  Extracting → {os.path.basename(native_out)} ...")
            r = subprocess.run([
                'ffmpeg', '-hide_banner', '-loglevel', 'error',
                '-i', video, '-map', f'0:{stream_idx}',
                '-c:s', 'copy', '-y', native_out
            ], timeout=300)
            if r.returncode == 0 and os.path.isfile(native_out):
                print(f"  Done: {os.path.basename(native_out)}")
            else:
                print("  Extraction failed.")
        elif codec in {'hdmv_pgs_subtitle', 'pgssub'}:
            if not ensure_pgsreader() or not ensure_easyocr():
                return
            print(f"  Extracting PGS → {os.path.basename(out)} (OCR, may take a while)...")
            if _extract_pgs(video, stream_idx, out):
                print(f"  Done: {os.path.basename(out)}")
            else:
                print("  PGS extraction failed.")
        else:
            print(f"  Extracting DVD/DVB subtitle → {os.path.basename(out)} ...")
            if not _extract_vobsub(video, stream_idx, out):
                print("  Could not extract automatically.")

    else:
        print(f"  Codec '{codec}' not yet supported for direct extraction.")
        print("  Try: ffmpeg -i video -map 0:s:N -c:s srt output.srt")

# ---------- MP4 → MKV remux --------------------------------------------------

_LANG_ISO1_TO_639_2 = {
    'en': 'eng', 'fr': 'fre', 'de': 'ger', 'es': 'spa', 'it': 'ita',
    'pt': 'por', 'nl': 'dut', 'ru': 'rus', 'ja': 'jpn', 'zh': 'chi',
    'ko': 'kor', 'ar': 'ara', 'pl': 'pol', 'sv': 'swe', 'no': 'nor',
    'da': 'dan', 'fi': 'fin', 'cs': 'cze', 'tr': 'tur', 'hu': 'hun',
}
_SUB_EXTS = ('.srt', '.ass', '.ssa', '.vtt', '.sup', '.sub')


def _do_remux(video_path, out_path):
    """Stream-copy video_path → out_path (MKV). Returns True on success."""
    import shutil
    use_mkvmerge = bool(shutil.which('mkvmerge'))
    if use_mkvmerge:
        print(f"  mkvmerge: {os.path.basename(video_path)} → {os.path.basename(out_path)}")
        cmd = ['mkvmerge', '-o', out_path, video_path]
    else:
        print(f"  ffmpeg stream copy (mkvmerge not found): {os.path.basename(video_path)} → {os.path.basename(out_path)}")
        cmd = ['ffmpeg', '-hide_banner', '-loglevel', 'error',
               '-i', video_path, '-c', 'copy', '-y', out_path]
    try:
        r = subprocess.run(cmd, timeout=600)
    except subprocess.TimeoutExpired:
        print("  Timed out.")
        return False
    if r.returncode == 0 and os.path.isfile(out_path):
        return True
    print("  Remux failed.")
    if os.path.exists(out_path):
        os.remove(out_path)
    return False


def _offer_mp4_remux(video_path):
    """If video_path is an MP4, offer (default yes) to remux to MKV first.
    Returns the path to use going forward (MKV on success, original otherwise)."""
    if not video_path.lower().endswith('.mp4'):
        return video_path
    base    = os.path.splitext(video_path)[0]
    mkv_out = base + '.mkv'
    print(f"\n  '{os.path.basename(video_path)}' is an MP4.")
    print("  MKV handles all subtitle types; MP4 only supports mov_text (SRT).")
    if os.path.exists(mkv_out):
        print(f"  MKV already exists: {os.path.basename(mkv_out)}")
        resp = input("  Use existing MKV? [Y/n]: ").strip().lower()
        if resp != 'n':
            return mkv_out
        return video_path
    resp = input("  Convert to MKV now (lossless)? [Y/n]: ").strip().lower()
    if resp == 'n':
        return video_path
    if _do_remux(video_path, mkv_out):
        in_mb  = os.path.getsize(video_path) / 1_048_576
        out_mb = os.path.getsize(mkv_out)    / 1_048_576
        print(f"  Done: {os.path.basename(mkv_out)}  ({in_mb:.0f} MB → {out_mb:.0f} MB)")
        resp = input("  Delete original MP4? [y/N]: ").strip().lower()
        if resp == 'y':
            os.remove(video_path)
            print(f"  Deleted: {os.path.basename(video_path)}")
        return mkv_out
    return video_path


def _detect_lang_tag(sub_path):
    """Guess ISO 639-2 language tag from filename stem (e.g. video.en.srt → eng)."""
    stem = os.path.splitext(os.path.basename(sub_path))[0]
    parts = stem.rsplit('.', 1)
    if len(parts) == 2:
        code = parts[1].lower()
        if code in _LANG_ISO1_TO_639_2:
            return _LANG_ISO1_TO_639_2[code]
        if len(code) == 3 and code.isalpha():
            return code
    return ''


def remux_mp4_to_mkv():
    """Mode 6: remux MP4 (or any container) to MKV — stream copy, no re-encode."""
    print("\n  MP4 → MKV")
    all_vid   = list_files(VIDEO_EXTS, "video")
    mp4_files = [f for f in all_vid if f.lower().endswith('.mp4')]

    if mp4_files:
        candidates = mp4_files
    else:
        print("  (no .mp4 found — showing all video files)")
        candidates = all_vid

    if candidates:
        video = pick_file(candidates, "  Choose file to remux (0 to cancel)")
    else:
        video = input("  Enter path to video file (0 to cancel): ").strip()
        if video == '0':
            return
    if not video:
        return
    if not os.path.isfile(video):
        print("  File not found.")
        return

    base = os.path.splitext(video)[0]
    out  = base + '.mkv'
    if os.path.exists(out):
        print(f"  Output already exists: {os.path.basename(out)}")
        resp = input("  Overwrite? [y/N]: ").strip().lower()
        if resp != 'y':
            print("  Cancelled.")
            return

    if _do_remux(video, out):
        in_mb  = os.path.getsize(video) / 1_048_576
        out_mb = os.path.getsize(out)   / 1_048_576
        print(f"  Done: {os.path.basename(out)}  ({in_mb:.0f} MB → {out_mb:.0f} MB)")
        resp = input("  Delete original? [y/N]: ").strip().lower()
        if resp == 'y':
            os.remove(video)
            print(f"  Deleted: {os.path.basename(video)}")


def embed_subs_mode():
    """Mode 7: soft-mux a subtitle file into a video using mkvmerge."""
    if not ensure_mkvtoolnix():
        return

    # --- pick video ---
    print("\n  EMBED: Video files in current directory:")
    vid_files = list_files(VIDEO_EXTS, "video")
    if vid_files:
        video = pick_file(vid_files, "  Choose video (0 to cancel)")
    else:
        video = input("  Enter path to video file (0 to cancel): ").strip()
        if video == '0':
            return
    if not video or not os.path.isfile(video):
        print("  No valid video selected.")
        return

    # offer MP4 → MKV before anything else
    video = _offer_mp4_remux(video)

    # --- pick subtitle file ---
    sub_files = sorted(
        f for f in os.listdir('.')
        if f.lower().endswith(_SUB_EXTS) and not f.endswith('.idx')
    )
    if sub_files:
        print("\n  Subtitle files in current directory:")
        for i, f in enumerate(sub_files, 1):
            print(f"    {i}: {f}")
        sub = pick_file(sub_files, "  Choose subtitle file (0 to cancel)")
    else:
        sub = input("  Enter path to subtitle file (0 to cancel): ").strip()
        if sub == '0':
            return
    if not sub or not os.path.isfile(sub):
        print("  No valid subtitle file selected.")
        return

    # --- language tag ---
    detected = _detect_lang_tag(sub)
    if detected:
        print(f"  Detected language tag: {detected}")
        resp = input(f"  Use '{detected}'? [Y/n]: ").strip().lower()
        lang = detected if resp != 'n' else ''
    else:
        lang = ''
    if not lang:
        lang = input("  Enter ISO 639-2 language tag (e.g. eng, fre) or Enter to skip: ").strip().lower()

    # --- build mkvmerge command ---
    base    = os.path.splitext(video)[0]
    tmp_out = base + '._embed_tmp.mkv'

    cmd = ['mkvmerge', '-o', tmp_out, video]
    if lang:
        cmd += ['--language', f'0:{lang}']
    cmd.append(sub)

    print(f"\n  Embedding {os.path.basename(sub)} → {os.path.basename(video)} ...")
    try:
        r = subprocess.run(cmd, timeout=600)
    except subprocess.TimeoutExpired:
        print("  Timed out.")
        return

    if r.returncode not in (0, 1) or not os.path.isfile(tmp_out):
        # mkvmerge returns 1 for warnings (still produces output)
        print("  mkvmerge failed.")
        if os.path.exists(tmp_out):
            os.remove(tmp_out)
        return

    # replace original with muxed file
    os.replace(tmp_out, video)
    print(f"  Done: subtitle embedded into {os.path.basename(video)}")

    resp = input("  Delete separate subtitle file? [y/N]: ").strip().lower()
    if resp == 'y':
        os.remove(sub)
        # also remove .idx if present alongside .sub
        idx = os.path.splitext(sub)[0] + '.idx'
        if os.path.exists(idx):
            os.remove(idx)
        print(f"  Deleted: {os.path.basename(sub)}")


def _extract_all_noninteractive(video_path):
    """--extract-all: dump every subtitle track + CC without prompting."""
    if not os.path.isfile(video_path):
        print(f"File not found: {video_path}", file=sys.stderr)
        sys.exit(1)

    print(f"Extracting all subtitles from: {video_path}")
    streams = probe_subtitle_streams(video_path)

    extracted = 0
    for s in streams:
        codec      = s.get('codec_name', '')
        stream_idx = s.get('index')
        lang       = s.get('tags', {}).get('language', '')
        out        = _sub_out_path(video_path, lang or str(stream_idx))

        if codec in _TEXT_SUB_CODECS:
            if _extract_text_track(video_path, stream_idx, out):
                print(f"  Extracted text track {stream_idx} → {os.path.basename(out)}")
                extracted += 1
        elif codec in {'hdmv_pgs_subtitle', 'pgssub'}:
            native_out = os.path.splitext(video_path)[0] + (f'.{lang}' if lang else f'.{stream_idx}') + '.sup'
            r = subprocess.run([
                'ffmpeg', '-hide_banner', '-loglevel', 'error',
                '-i', video_path, '-map', f'0:{stream_idx}', '-c:s', 'copy', '-y', native_out
            ], timeout=300)
            if r.returncode == 0 and os.path.isfile(native_out):
                print(f"  Extracted PGS track {stream_idx} → {os.path.basename(native_out)}")
                extracted += 1
        elif codec in _IMAGE_SUB_CODECS:
            native_out = os.path.splitext(video_path)[0] + (f'.{lang}' if lang else f'.{stream_idx}') + '.sub'
            r = subprocess.run([
                'ffmpeg', '-hide_banner', '-loglevel', 'error',
                '-i', video_path, '-map', f'0:{stream_idx}', '-c:s', 'copy', '-y', native_out
            ], timeout=300)
            if r.returncode == 0 and os.path.isfile(native_out):
                print(f"  Extracted VOB SUB track {stream_idx} → {os.path.basename(native_out)}")
                extracted += 1

    # try ccextractor for broadcast CC
    import shutil as _sh
    cce = _sh.which('ccextractor') or _sh.which('ccextractorwin')
    if cce:
        cc_out = _sub_out_path(video_path, 'cc')
        r = subprocess.run([cce, video_path, '-o', cc_out], timeout=600,
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        if r.returncode == 0 and os.path.isfile(cc_out):
            print(f"  Extracted CC → {os.path.basename(cc_out)}")
            extracted += 1

    print(f"Done. {extracted} track(s) extracted.")
    sys.exit(0)

# ---------- Mode 8: Burnt-in subtitle OCR and removal -----------------------

def _probe_video_size(video_path):
    """Return (width, height) of the first video stream."""
    try:
        r = subprocess.run([
            'ffprobe', '-v', 'quiet', '-print_format', 'json',
            '-show_streams', '-select_streams', 'v:0', video_path
        ], capture_output=True, text=True, timeout=15)
        s = json.loads(r.stdout)['streams'][0]
        return int(s['width']), int(s['height'])
    except Exception:
        return 1920, 1080


def _video_duration(video_path):
    try:
        r = subprocess.run([
            'ffprobe', '-v', 'quiet', '-show_entries', 'format=duration',
            '-print_format', 'json', video_path
        ], capture_output=True, text=True, timeout=15)
        return float(json.loads(r.stdout)['format']['duration'])
    except Exception:
        return 0.0


def scan_burnt_in_subs(video_path, fps=1, crop_fraction=0.28):
    """
    OCR burnt-in subtitles from the bottom crop_fraction of each frame at fps.
    Returns (entries, region):
      entries = [(start_sec, end_sec, text), ...]
      region  = (x, y, w, h) estimated black-box in full-frame pixels, or None
    """
    if not ensure_easyocr():
        return [], None
    import easyocr

    width, height = _probe_video_size(video_path)
    crop_y        = int(height * (1.0 - crop_fraction))
    crop_h        = height - crop_y
    duration      = _video_duration(video_path)
    est           = int(duration * fps) if duration else '?'

    print(f"  Extracting frames at {fps}fps (~{est} frames, bottom {int(crop_fraction*100)}%)...")

    import tempfile
    with tempfile.TemporaryDirectory() as tmpdir:
        frame_pat = os.path.join(tmpdir, 'f_%06d.png')
        r = subprocess.run([
            'ffmpeg', '-hide_banner', '-loglevel', 'error', '-i', video_path,
            '-vf', f'crop={width}:{crop_h}:0:{crop_y},fps={fps}',
            frame_pat
        ], timeout=7200)
        if r.returncode != 0:
            print("  Frame extraction failed.")
            return [], None

        frames = sorted(glob.glob(os.path.join(tmpdir, 'f_*.png')))
        if not frames:
            print("  No frames extracted.")
            return [], None

        print(f"  OCR on {len(frames)} frames (first run downloads ~170 MB model)...")
        reader = easyocr.Reader(['en'], verbose=False)

        entries      = []
        current_text = None
        start_time   = None
        all_bboxes   = []   # (x1,y1,x2,y2) in full-frame pixels

        for i, fp in enumerate(frames):
            ts = i / fps
            try:
                results = reader.readtext(fp, detail=1, paragraph=False)
            except Exception:
                results = []

            texts = []
            for (bbox, text, conf) in results:
                if conf < 0.35 or not text.strip():
                    continue
                texts.append(text.strip())
                bx1 = int(min(p[0] for p in bbox))
                by1 = int(min(p[1] for p in bbox)) + crop_y
                bx2 = int(max(p[0] for p in bbox))
                by2 = int(max(p[1] for p in bbox)) + crop_y
                all_bboxes.append((bx1, by1, bx2, by2))

            line = postprocess_text(' '.join(texts)) if texts else ''

            if line:
                if line != current_text:
                    if current_text is not None:
                        entries.append((start_time, ts, current_text))
                    current_text = line
                    start_time   = ts
            else:
                if current_text is not None:
                    entries.append((start_time, ts, current_text))
                    current_text = None

        if current_text is not None and start_time is not None:
            entries.append((start_time, len(frames) / fps, current_text))

        entries = [(s, e, t) for s, e, t in entries if e - s >= 0.4]

        region = None
        if all_bboxes:
            x1 = max(0,     min(b[0] for b in all_bboxes) - 20)
            y1 = max(0,     min(b[1] for b in all_bboxes) - 15)
            x2 = min(width, max(b[2] for b in all_bboxes) + 20)
            y2 = min(height,max(b[3] for b in all_bboxes) + 15)
            region = (x1, y1, x2 - x1, y2 - y1)

    return entries, region


def remove_burnt_in_region(video_path, x, y, w, h, output_path):
    """
    Remove a rectangular region using ffmpeg delogo filter.
    Re-encodes video; audio and subtitle tracks are stream-copied.

    Limitation: pixels under the box are gone — delogo blends from
    surrounding pixels. Simple/static backgrounds look good; busy action
    scenes will show visible blending artifacts.
    """
    print(f"  Applying delogo: x={x} y={y} w={w} h={h}")
    print("  Re-encoding video (libx264 CRF 18) — this will take a while...")
    cmd = [
        'ffmpeg', '-hide_banner', '-loglevel', 'error',
        '-i', video_path,
        '-vf', f'delogo=x={x}:y={y}:w={w}:h={h}:show=0',
        '-c:v', 'libx264', '-crf', '18', '-preset', 'medium',
        '-c:a', 'copy', '-c:s', 'copy',
        '-y', output_path
    ]
    try:
        r = subprocess.run(cmd, timeout=7200)
        return r.returncode == 0 and os.path.isfile(output_path)
    except subprocess.TimeoutExpired:
        print("  Timed out.")
        return False


def _burnt_in_two_file_sync():
    """
    Two-file workflow: OCR burnt-in subs from a CC copy, then sync the
    resulting SRT against a clean (no burnt-in subs) copy of the same video.
    Useful when you have both the CC broadcast version and a clean retail copy.
    """
    print("\n  TWO-FILE SYNC")
    print("  Step 1 of 2 — pick the video WITH burnt-in subtitles (the CC copy):")
    vid_files = list_files(VIDEO_EXTS, "video")
    if vid_files:
        cc_video = pick_file(vid_files, "  Choose CC video (0 to cancel)")
    else:
        cc_video = input("  Path to CC video (0 to cancel): ").strip()
        if cc_video == '0':
            return
    if not cc_video or not os.path.isfile(cc_video):
        print("  No valid file selected.")
        return

    print("\n  Step 2 of 2 — pick the CLEAN video (no burnt-in subs):")
    if vid_files:
        remaining = [f for f in vid_files if f != cc_video]
        if remaining:
            for i, f in enumerate(remaining, 1):
                print(f"  {i}: {f}")
            clean_video = pick_file(remaining, "  Choose clean video (0 to cancel)")
        else:
            clean_video = input("  Path to clean video (0 to cancel): ").strip()
            if clean_video == '0':
                return
    else:
        clean_video = input("  Path to clean video (0 to cancel): ").strip()
        if clean_video == '0':
            return
    if not clean_video or not os.path.isfile(clean_video):
        print("  No valid file selected.")
        return

    print("\n  Scan rate (affects timing accuracy and speed):")
    print("    1: 1 fps  - ±1s accuracy, fast        [default]")
    print("    2: 2 fps  - ±0.5s accuracy, slower")
    fps = 2 if (input("  Choose [1]: ").strip() == '2') else 1

    # ── Step A: OCR the CC video ──────────────────────────────────────────────
    print(f"\n  Scanning '{os.path.basename(cc_video)}' for burnt-in subtitles...")
    entries, _region = scan_burnt_in_subs(cc_video, fps=fps)

    if not entries:
        print("  No subtitles detected in the CC video. Aborting.")
        return

    print(f"  Detected {len(entries)} subtitle entries.")

    import tempfile
    fd, raw_srt = tempfile.mkstemp(suffix='-burntocr-raw.srt')
    os.close(fd)
    with open(raw_srt, 'w', encoding='utf-8') as f:
        for i, (s, e, t) in enumerate(entries, 1):
            f.write(f"{i}\n{seconds_to_srt(s)} --> {seconds_to_srt(e)}\n{t}\n\n")

    # ── Step B: sync the raw SRT against the clean video ─────────────────────
    base     = os.path.splitext(clean_video)[0]
    out_srt  = f"{base}-burntocr-synced.srt"

    print(f"\n  Syncing OCR'd SRT against '{os.path.basename(clean_video)}'...")
    if not ensure_ffsubsync():
        # No ffsubsync — just write the raw SRT alongside the clean video
        import shutil
        shutil.copy(raw_srt, out_srt)
        os.remove(raw_srt)
        print(f"  ffsubsync not available — wrote unsynced SRT: {os.path.basename(out_srt)}")
        print("  You can sync it later with Mode 1 (SYNC).")
        return

    ok, _offset = sync_with_ffsubsync(clean_video, raw_srt, out_srt)
    os.remove(raw_srt)

    if ok and os.path.isfile(out_srt):
        kb = os.path.getsize(out_srt) / 1024
        print(f"\n  Done: {os.path.basename(out_srt)}  ({kb:.0f} KB, {len(entries)} entries)")
        print("  This SRT is timed to the clean video and ready to use.")
        # Offer manual fine-tune: OCR timing is at best ±0.5s so a nudge may help
        print("\n  Fine-tune timing?")
        print("    Subtitle text appears BEFORE you hear it  →  use a POSITIVE number (+0.5)")
        print("    You hear the sound BEFORE the text appears →  use a NEGATIVE number (-0.5)")
        print("    Enter to skip.")
        while True:
            resp = input("  Offset seconds [Enter to skip]: ").strip()
            if resp == '' or resp == '0':
                break
            offset = parse_offset(resp)
            if offset is None:
                print("  Invalid — enter a number like 0.5 or -1.2.")
                continue
            import shutil
            tmp = out_srt + '.bak'
            shutil.copy(out_srt, tmp)
            shift_srt(tmp, out_srt, offset)
            os.remove(tmp)
            print(f"  Applied {offset:+.3f}s offset to {os.path.basename(out_srt)}")
            again = input("  Try another offset? [y/N]: ").strip().lower()
            if again != 'y':
                break
            # Load from the current (already-shifted) file each time — offsets stack
    else:
        print("  Sync failed. The raw OCR SRT has been discarded.")
        print("  Tip: re-run with '1: Transcribe only' on the CC video and sync manually.")


def burnt_in_subs_mode():
    """Mode 8: OCR burnt-in subtitles → SRT and/or remove them from video."""
    print("\n  BURNSUBS — what would you like to do?")
    print("    1: Transcribe only   - OCR burnt-in subs → SRT")
    print("    2: Remove only       - erase subtitle band from video (re-encodes)")
    print("    3: Both              - transcribe then remove  [default]")
    print("    4: Two-file sync     - OCR subs from CC copy, sync SRT to clean copy")
    print("    0: Cancel")
    while True:
        ch = input("  Choose [3]: ").strip() or '3'
        if ch in ('0', '1', '2', '3', '4'):
            break
        print("  Enter 0-4.")
    if ch == '0':
        return

    # ── Option 4: two-file workflow ──────────────────────────────────────────
    if ch == '4':
        _burnt_in_two_file_sync()
        return

    # ── Options 1-3: single-file workflow ────────────────────────────────────
    print("\n  BURNSUBS: Video files in current directory:")
    vid_files = list_files(VIDEO_EXTS, "video")
    if vid_files:
        video = pick_file(vid_files, "  Choose video (0 to cancel)")
    else:
        video = input("  Enter path to video file (0 to cancel): ").strip()
        if video == '0':
            return
    if not video or not os.path.isfile(video):
        print("  No valid video selected.")
        return

    video = _offer_mp4_remux(video)

    do_ocr    = ch in ('1', '3')
    do_remove = ch in ('2', '3')

    print("\n  Scan rate (affects timing accuracy and speed):")
    print("    1: 1 fps  - ±1s accuracy, fast        [default]")
    print("    2: 2 fps  - ±0.5s accuracy, slower")
    fps = 2 if (input("  Choose [1]: ").strip() == '2') else 1

    region   = None
    srt_path = None

    if do_ocr:
        print(f"\n  Scanning for burnt-in subtitles...")
        entries, region = scan_burnt_in_subs(video, fps=fps)

        if not entries:
            print("  No subtitles detected.")
            if do_remove and region is None:
                print("  Cannot auto-detect removal region. Run transcribe pass first, or enter region manually.")
                do_remove = True   # fall through to manual entry below
        else:
            print(f"  Detected {len(entries)} subtitle entries.")
            base     = os.path.splitext(video)[0]
            srt_path = f"{base}-burntocr.srt"
            with open(srt_path, 'w', encoding='utf-8') as f:
                for i, (s, e, t) in enumerate(entries, 1):
                    f.write(f"{i}\n{seconds_to_srt(s)} --> {seconds_to_srt(e)}\n{t}\n\n")
            print(f"  SRT: {os.path.basename(srt_path)}")

    if do_remove:
        if region:
            x, y, w, h = region
            print(f"\n  Auto-detected subtitle region: x={x} y={y} w={w} h={h}")
            print("  Note: pixels under the black box cannot be recovered.")
            print("        delogo blends from surrounding pixels — looks good on")
            print("        simple backgrounds, may show artifacts on busy scenes.")
            if input("  Adjust region? [y/N]: ").strip().lower() == 'y':
                region = None

        if region is None:
            vw, vh = _probe_video_size(video)
            print(f"\n  Enter subtitle region (video is {vw}x{vh}).")
            print("  Format: x y width height  — e.g. for full-width bottom band: 0 920 1920 100")
            while True:
                raw = input("  Region (0 to cancel): ").strip()
                if raw == '0':
                    return
                try:
                    x, y, w, h = map(int, raw.split())
                    region = (x, y, w, h)
                    break
                except ValueError:
                    print("  Enter four integers.")

        x, y, w, h = region
        base = os.path.splitext(video)[0]
        ext  = os.path.splitext(video)[1]
        out  = f"{base}-clean{ext}"

        if input(f"\n  Write to {os.path.basename(out)} — proceed? [Y/n]: ").strip().lower() == 'n':
            return

        if remove_burnt_in_region(video, x, y, w, h, out):
            mb = os.path.getsize(out) / 1_048_576
            print(f"  Done: {os.path.basename(out)}  ({mb:.0f} MB)")
            if input("  Delete original? [y/N]: ").strip().lower() == 'y':
                os.remove(video)
                print(f"  Deleted: {os.path.basename(video)}")
        else:
            print("  Removal failed.")


# ---------- Mode 1: Sync (with language detection + transcribe/translate) ----

_LANG_NAMES = {
    'id': 'Indonesian', 'ms': 'Malay', 'fr': 'French', 'es': 'Spanish',
    'de': 'German',     'it': 'Italian', 'pt': 'Portuguese', 'nl': 'Dutch',
    'ru': 'Russian',    'zh-cn': 'Chinese', 'zh-tw': 'Chinese (Traditional)',
    'ja': 'Japanese',   'ko': 'Korean', 'ar': 'Arabic', 'th': 'Thai',
    'vi': 'Vietnamese', 'pl': 'Polish', 'sv': 'Swedish', 'no': 'Norwegian',
    'da': 'Danish',     'fi': 'Finnish', 'tr': 'Turkish', 'cs': 'Czech',
    'hu': 'Hungarian',  'ro': 'Romanian', 'uk': 'Ukrainian', 'tl': 'Filipino',
}


def ensure_langdetect():
    try:
        import langdetect  # noqa: F401
        return True
    except ImportError:
        pass
    print("\nlangdetect not installed (used for subtitle language detection).")
    if input("  Install it now? [Y/n]: ").strip().lower() == 'n':
        return False
    if not _pip_install('langdetect'):
        return False
    import importlib
    importlib.invalidate_caches()
    try:
        import langdetect  # noqa: F401
        return True
    except ImportError:
        return False


def _srt_detect_language(srt_path):
    """Detect the language of an SRT file.
    Returns (lang_code, lang_name) or (None, None) if detection fails.
    Uses langdetect for Latin-script languages (Indonesian, Malay, French, etc.)
    and falls back to Unicode character analysis for non-Latin scripts.
    """
    entries = parse_srt_full(srt_path, limit=60)
    if not entries:
        return None, None

    all_text = ' '.join(t for _, _, t in entries)
    letters  = [c for c in all_text if c.isalpha()]
    if not letters:
        return None, None

    # Fast path: non-Latin scripts (CJK, Arabic, Cyrillic, etc.)
    non_ascii = sum(1 for c in letters if ord(c) > 127)
    if (non_ascii / len(letters)) > 0.15:
        # Try langdetect for the name, fall back to 'unknown'
        try:
            if ensure_langdetect():
                from langdetect import detect
                code = detect(all_text[:2000])
                return code, _LANG_NAMES.get(code, code.upper())
        except Exception:
            pass
        return 'xx', 'non-Latin script'

    # Latin-script: needs langdetect to distinguish Indonesian/Malay/English/etc.
    if not ensure_langdetect():
        return None, None
    try:
        from langdetect import detect, DetectorFactory
        DetectorFactory.seed = 0          # make results deterministic
        code = detect(all_text[:2000])
        if code == 'en':
            return 'en', 'English'
        return code, _LANG_NAMES.get(code, code.upper())
    except Exception:
        return None, None


def split_sync_intro_show(video):
    """
    Two-pass sync for series episodes with a recurring intro.

    Pass 1: sync intro.srt against the video audio → correct timing for the
            intro; the synced intro entries are used directly in the output.
    Pass 2: extract show audio from where the intro ends, sync the show SRT
            (which is treated as show-only content, starting near 00:00:00)
            against that clip → offset_B, then shift timestamps to absolute
            video time by adding intro_end_video.

    The episode SRT should cover only the show content; it does not need
    intro subtitles — those come from intro.srt.
    """
    if not ensure_ffsubsync():
        print("  ffsubsync is required for split sync.")
        return

    # --- Locate intro.srt ---
    intro_srt = 'intro.srt'
    if not os.path.isfile(intro_srt):
        vid_dir = os.path.dirname(os.path.abspath(video))
        intro_srt = os.path.join(vid_dir, 'intro.srt')
    if os.path.isfile(intro_srt):
        ans = input(f"  Found {os.path.basename(intro_srt)} — use it as intro reference? [y/N]: ").strip().lower()
        if ans != 'y':
            intro_srt = ''
    if not intro_srt or not os.path.isfile(intro_srt):
        print("  SRT files in current directory:")
        srt_candidates = list_files('.srt', 'SRT')
        if not srt_candidates:
            print("  No SRT files found — cannot run split sync.")
            return
        intro_srt = pick_file(srt_candidates, "  Choose intro SRT (0 to cancel)")
        if not intro_srt:
            return
    print(f"  Intro reference: {os.path.basename(intro_srt)}")

    # --- Pick show SRT (show content only, need not contain intro lines) ---
    print("\n  Show SRT files (show content only — intro comes from intro.srt):")
    srt_files = [f for f in list_files('.srt', 'SRT') if f != os.path.basename(intro_srt)]
    if srt_files:
        episode_srt = pick_file(srt_files, "  Choose show SRT (0 to cancel)")
    else:
        episode_srt = input("  Path to show SRT (0 to cancel): ").strip()
        if episode_srt == '0':
            return
    if not episode_srt or not os.path.isfile(episode_srt):
        print("  No valid SRT selected.")
        return

    import tempfile

    # ── Pass 1: sync intro against the full video ─────────────────────────────
    print(f"\n  Pass 1 of 2 — syncing {os.path.basename(intro_srt)} against {os.path.basename(video)}...")
    fd, intro_synced_tmp = tempfile.mkstemp(suffix='.srt')
    os.close(fd)

    ok1, offset_A = sync_with_ffsubsync(video, intro_srt, intro_synced_tmp)
    if not ok1 or offset_A is None:
        print("  Intro sync failed — cannot determine split point.")
        try: os.remove(intro_synced_tmp)
        except OSError: pass
        return

    print(f"  Intro offset: {offset_A:+.3f}s")

    # The synced intro entries already have correct absolute timestamps.
    intro_synced_entries = parse_srt_full(intro_synced_tmp)
    try: os.remove(intro_synced_tmp)
    except OSError: pass

    if not intro_synced_entries:
        print("  Could not read synced intro SRT — aborting.")
        return

    intro_end_video = max(e for _, e, _ in intro_synced_entries)
    print(f"  Intro ends at {seconds_to_srt(intro_end_video)} in video")
    print(f"  Intro: {len(intro_synced_entries)} entries ready")

    # Write a preview file so the user can open it and check before deciding
    intro_preview = os.path.splitext(intro_srt)[0] + '-synced-preview.srt'
    with open(intro_preview, 'w', encoding='utf-8') as f:
        for i, (s, e, t) in enumerate(intro_synced_entries, 1):
            f.write(f"{i}\n{seconds_to_srt(s)} --> {seconds_to_srt(e)}\n{t}\n\n")
    print(f"  Preview written: {os.path.basename(intro_preview)}")
    print("  Framerate correction (if needed) was applied automatically.")
    print("  Open the preview in a text editor or subtitle viewer to check timing.")
    input("  Press Enter when ready to continue...")

    # Optional manual nudge on the intro before combining
    print("\n  Intro timing fine-tune (or Enter to skip):")
    print("    Subtitle text appears BEFORE you hear it  →  positive number (+3.0)")
    print("    You hear the sound BEFORE the text appears →  negative number (-3.0)")
    while True:
        resp = input("  Intro offset seconds [Enter to skip]: ").strip()
        if resp == '' or resp == '0':
            break
        extra = parse_offset(resp)
        if extra is None:
            print("  Invalid — enter a number like 3.0 or -1.5.")
            continue
        intro_synced_entries = [
            (max(0.0, s + extra), max(0.0, e + extra), t)
            for s, e, t in intro_synced_entries
        ]
        intro_end_video = max(e for _, e, _ in intro_synced_entries)
        with open(intro_preview, 'w', encoding='utf-8') as f:
            for i, (s, e, t) in enumerate(intro_synced_entries, 1):
                f.write(f"{i}\n{seconds_to_srt(s)} --> {seconds_to_srt(e)}\n{t}\n\n")
        print(f"  Applied {extra:+.3f}s — intro now ends at {seconds_to_srt(intro_end_video)}")
        print(f"  Preview updated: {os.path.basename(intro_preview)}")
        again = input("  Try another offset? [y/N]: ").strip().lower()
        if again != 'y':
            break

    # ── Extract show audio from intro_end onwards ─────────────────────────────
    print(f"\n  Extracting show audio from {seconds_to_srt(intro_end_video)}...")
    fd2, show_wav = tempfile.mkstemp(suffix='.wav')
    os.close(fd2)
    r = subprocess.run([
        'ffmpeg', '-hide_banner', '-loglevel', 'error',
        '-i', video, '-ss', str(intro_end_video),
        '-vn', '-ac', '1', '-ar', '16000', '-y', show_wav
    ], timeout=600)
    if r.returncode != 0:
        print("  Failed to extract show audio — aborting.")
        try: os.remove(show_wav)
        except OSError: pass
        return

    # ── Pass 2: sync show SRT against the show audio clip ────────────────────
    # ffsubsync finds the best alignment regardless of what offset the show SRT
    # currently has; output timestamps are relative to the clip start (i.e.
    # relative to intro_end_video).
    show_ep = parse_srt_full(episode_srt)
    print(f"  Pass 2 of 2 — syncing {len(show_ep)} show entries against show audio...")
    fd3, show_synced_tmp = tempfile.mkstemp(suffix='.srt')
    os.close(fd3)

    ok2, offset_B = sync_with_ffsubsync(show_wav, episode_srt, show_synced_tmp)
    try: os.remove(show_wav)
    except OSError: pass

    if ok2 and offset_B is not None:
        print(f"  Show offset: {offset_B:+.3f}s (relative to intro end)")
        show_synced_entries = parse_srt_full(show_synced_tmp)
    else:
        print("  Show sync failed — writing show entries unsynced as fallback.")
        show_synced_entries = show_ep
    try: os.remove(show_synced_tmp)
    except OSError: pass

    # ── Merge: intro (absolute) + show (relative → absolute) ─────────────────
    base = os.path.splitext(episode_srt)[0]
    out  = f"{base}-splitsync.srt"

    with open(out, 'w', encoding='utf-8') as f:
        idx = 1
        # Intro: timestamps already correct from pass 1
        for s, e, t in intro_synced_entries:
            f.write(f"{idx}\n{seconds_to_srt(s)} --> {seconds_to_srt(e)}\n{t}\n\n")
            idx += 1
        # Show: add intro_end_video to convert clip-relative → absolute video time
        for s, e, t in show_synced_entries:
            ws = s + intro_end_video
            we = max(ws + 0.1, e + intro_end_video)
            f.write(f"{idx}\n{seconds_to_srt(ws)} --> {seconds_to_srt(we)}\n{t}\n\n")
            idx += 1

    kb = os.path.getsize(out) / 1024
    print(f"\n  Done: {os.path.basename(out)}  ({kb:.0f} KB, {idx-1} entries)")
    print(f"  Intro: {len(intro_synced_entries)} entries  (offset {offset_A:+.3f}s)")
    if ok2 and offset_B is not None:
        print(f"  Show:  {len(show_synced_entries)} entries  (offset {offset_B:+.3f}s from intro end)")


def sync_mode():
    global WHISPER_MODEL, WHISPER_TASK, WHISPER_LANGUAGE

    # --- Pick video ---
    print("\n  SYNC: Video files in current directory:")
    vid_files = list_files(VIDEO_EXTS, "video")
    if vid_files:
        video = pick_file(vid_files, "  Choose video by number or filename")
    else:
        video = input("  Enter path to video file (0 to cancel): ").strip()
        if video == '0':
            return
    if not video or not os.path.isfile(video):
        print("  No valid video selected.")
        return

    ffsubsync_ok = ensure_ffsubsync()
    whisper_ok   = WHISPER_AVAILABLE  # don't install just to show the menu

    # --- Sync method ---
    print("\n  Sync method:")
    print("    f: ffsubsync only       (fast, recommended) [default]")
    print("    w: Whisper only         (speech recognition)")
    print("    b: Both - ffsubsync + Whisper cross-check")
    print("    m: Manual offset        (enter seconds yourself)")
    print("    s: Split sync           (intro + show have different offsets, uses intro.srt)")
    print("    0: Cancel")
    while True:
        ch = input("  Choose or Enter for default: ").strip().lower()
        if ch == '':
            ch = 'f'
            break
        if ch in ('f', 'w', 'b', 'm', 's', '0'):
            break
        print("  Enter f, w, b, m, s or 0.")
    if ch == '0':
        return

    if ch == 's':
        split_sync_intro_show(video)
        return

    if ch in ('w', 'b'):
        whisper_ok = ensure_whisper()
        if not whisper_ok:
            print("  Whisper required for this method.")
            return
        print("\n  Whisper model:")
        for k, (name, desc) in WHISPER_MODELS.items():
            marker = " <-- default" if name == WHISPER_MODEL else ""
            print(f"    {k}: {name:20s} {desc}{marker}")
        choice = input("  Choose model [Enter for default]: ").strip()
        if choice in WHISPER_MODELS:
            WHISPER_MODEL = WHISPER_MODELS[choice][0]
        print(f"  Using: {WHISPER_MODEL}\n")

    # --- Pick SRT ---
    print("\n  SRT files in current directory:")
    srt_files = list_files('.srt', "SRT")
    if srt_files:
        src = pick_file(srt_files, "  Choose SRT by number or filename")
    else:
        src = input("  Enter path to .srt file (0 to cancel): ").strip()
        if src == '0':
            return
    if not src or not os.path.isfile(src):
        print("  No valid SRT selected.")
        return

    # Detect SRT language from the actual subtitle text — offer English if non-English
    also_english = False
    lang_code, lang_name = _srt_detect_language(src)
    if lang_code and lang_code != 'en':
        print(f"\n  Detected language: {lang_name}.")
        if ensure_whisper():
            whisper_ok = True
            also_english = input(
                f"  Also generate an English SRT via Whisper translate after sync? [Y/n]: "
            ).strip().lower() != 'n'

    # --- Sync ---
    base = os.path.splitext(src)[0]
    out  = f"{base}-synced.srt"
    print(f"\n  Syncing -> {os.path.basename(out)}")

    synced_ok = False
    if ch == 'f':
        ok, offset = sync_with_ffsubsync(video, src, out)
        if ok:
            if offset is not None:
                print(f"  Offset applied: {offset:+.3f} s")
            print(f"  Done: {os.path.basename(out)}")
            synced_ok = True
        else:
            print("  ffsubsync failed.")
            while True:
                resp = input("  Enter offset manually (seconds, e.g. -3.5) or Enter to skip: ").strip()
                if resp == '':
                    break
                offset = parse_offset(resp)
                if offset is None:
                    print("  Invalid.")
                else:
                    shift_srt(src, out, offset)
                    print(f"  Written -> {os.path.basename(out)}")
                    synced_ok = True
                    break

    elif ch == 'w':
        offset, n_matches, spread, err = compute_offset_whisper(src, video, WHISPER_MODEL)
        if not err:
            quality = "good" if spread < 2.0 else "moderate" if spread < 5.0 else "low"
            print(f"  Whisper offset: {offset:+.3f} s  ({n_matches} matches, spread {spread:.1f}s, {quality})")
            shift_srt(src, out, offset)
            print(f"  Done: {os.path.basename(out)}")
            synced_ok = True
        else:
            print(f"  Whisper failed: {err}")

    elif ch == 'm':
        print("    Subtitle text appears BEFORE you hear it  →  use a POSITIVE number (+0.52)")
        print("    You hear the sound BEFORE the text appears →  use a NEGATIVE number (-0.52)")
        print("    Enter 0 or blank to cancel.")
        last_offset = 0.0
        while True:
            hint = f"  Offset seconds [last: {last_offset:+.3f}]: "
            resp = input(hint).strip()
            if resp in ('0', ''):
                break
            offset = parse_offset(resp)
            if offset is None:
                print("  Invalid — enter a number like 1.5 or -0.52.")
                continue
            last_offset = offset
            shift_srt(src, out, offset)
            print(f"  Written -> {os.path.basename(out)}")
            synced_ok = True
            again = input("  Try another offset? [y/N]: ").strip().lower()
            if again != 'y':
                break
            # re-apply to original each time so offsets don't stack
            print("  (applying to original each time — offsets do not stack)")

    else:  # b
        if sync_single(video, src, out, ffsubsync_ok, whisper_ok, interactive=True):
            print(f"  Done: {os.path.basename(out)}")
            synced_ok = True
        else:
            while True:
                resp = input("\n  All methods failed. Enter offset manually or Enter to skip: ").strip()
                if resp == '':
                    break
                offset = parse_offset(resp)
                if offset is None:
                    print("  Invalid.")
                else:
                    shift_srt(src, out, offset)
                    print(f"  Written -> {os.path.basename(out)}")
                    synced_ok = True
                    break

    # --- Also generate English SRT? ---
    if also_english and whisper_ok:
        print("\n  Generating English SRT via Whisper translate...")
        WHISPER_TASK     = 'translate'
        WHISPER_LANGUAGE = None
        final = generate_and_sync(video, WHISPER_MODEL, ffsubsync_ok=ffsubsync_ok)
        if final:
            print(f"  English SRT: {os.path.basename(final)}")

    if synced_ok:
        offer_rename(video)


# ---------- Main -------------------------------------------------------------

def main():
    global WHISPER_MODEL, WHISPER_LANGUAGE, WHISPER_TASK

    if '--translate' in sys.argv:
        WHISPER_TASK     = 'translate'
        WHISPER_LANGUAGE = None   # auto-detect source; --lang overrides below
        print("Translate mode: Whisper will output English regardless of source language.")

    if '--extract-all' in sys.argv:
        idx = sys.argv.index('--extract-all')
        if idx + 1 < len(sys.argv):
            _extract_all_noninteractive(sys.argv[idx + 1])
        else:
            print("--extract-all requires a file path.", file=sys.stderr)
            sys.exit(1)

    if '--lang' in sys.argv:
        idx = sys.argv.index('--lang')
        if idx + 1 < len(sys.argv):
            WHISPER_LANGUAGE = sys.argv[idx + 1]
            print(f"Language override: {WHISPER_LANGUAGE}")
        else:
            print("--lang requires a language code (e.g. --lang fr). Using default.")
    elif '--lang-auto' in sys.argv:
        WHISPER_LANGUAGE = None
        print("Language: auto-detect")

    while True:
        print("\nWhat would you like to do?")
        print("  1: SYNC     - sync an existing SRT to the video")
        gen_label = "translate foreign audio → English SRT" if WHISPER_TASK == 'translate' \
                    else "create a new SRT by transcribing with Whisper"
        print(f"  2: GENERATE - {gen_label}")
        print("  3: BATCH    - sync all video+SRT pairs in this directory")
        print("  4: RENAME   - rename video + SRT to Plex format")
        print("  5: EXTRACT  - extract embedded subtitles / CC to SRT")
        print("  6: REMUX    - convert MP4 → MKV (stream copy, no re-encode)")
        print("  7: EMBED    - soft-mux subtitle file into video (mkvmerge)")
        print("  8: BURNSUBS - OCR burnt-in subs → SRT and/or erase from video")
        print("  0: Exit")
        while True:
            mode = input("Choose: ").strip()
            if mode in ('0', '1', '2', '3', '4', '5', '6', '7', '8'):
                break
            print("Please enter 0-8.")

        if mode == '0':
            print("Goodbye.")
            break

        # ---- Mode 4: Rename (has its own sub-menu loop) ---------------------
        if mode == '4':
            ocr_ok = ensure_easyocr()
            rename_menu(ocr_ok)
            continue

        # ---- Mode 5: Extract subtitles --------------------------------------
        if mode == '5':
            extract_subs_mode()
            continue

        # ---- Mode 6: Remux MP4 → MKV ----------------------------------------
        if mode == '6':
            remux_mp4_to_mkv()
            continue

        # ---- Mode 7: Embed subtitle into video ------------------------------
        if mode == '7':
            embed_subs_mode()
            continue

        # ---- Mode 8: Burnt-in subtitle OCR / removal ------------------------
        if mode == '8':
            burnt_in_subs_mode()
            continue

        # ---- Mode 1: Sync / transcribe / translate --------------------------
        if mode == '1':
            sync_mode()
            continue

        # ---- Mode 2: Generate SRT -------------------------------------------
        whisper_ok   = ensure_whisper()
        ffsubsync_ok = ensure_ffsubsync()

        if not whisper_ok:
            print("Whisper is required to generate an SRT.")
            continue

        if whisper_ok:
            print("\nWhisper model (larger = more accurate, more RAM, slower first load):")
            for k, (name, desc) in WHISPER_MODELS.items():
                marker = " <-- default" if name == WHISPER_MODEL else ""
                print(f"  {k}: {name:20s} {desc}{marker}")
            choice = input("Choose model [Enter for default]: ").strip()
            if choice in WHISPER_MODELS:
                WHISPER_MODEL = WHISPER_MODELS[choice][0]
            print(f"  Using: {WHISPER_MODEL}\n")

        # ---- Mode 3: Batch sync ---------------------------------------------
        if mode == '3':
            batch_sync(ffsubsync_ok, whisper_ok)
            continue

        print("\nVideo files in current directory:")
        vid_files = list_files(VIDEO_EXTS, "video")
        if vid_files:
            video = pick_file(vid_files, "Choose video by number or filename")
        else:
            video = input("Enter path to video file (0 to cancel): ").strip()
            if video == '0':
                continue
        if not video or not os.path.isfile(video):
            print("No valid video selected.")
            continue

        final = generate_and_sync(video, WHISPER_MODEL, ffsubsync_ok=ffsubsync_ok)
        if final:
            print(f"\nDone - final SRT: {final}")
            offer_rename(video)


if __name__ == '__main__':
    main()

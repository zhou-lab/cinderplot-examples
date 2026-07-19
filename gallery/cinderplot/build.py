#!/usr/bin/env python3
"""Build the cinderplot scatterplot gallery page (zhou-lab.github.io/cinderplot.html).

Single source of truth: VARIANTS below. For each we render the cinderplot SVG
and the ggplot2 reference (PDF -> PNG), then emit:
  - gallery/cinderplot.html          (relative asset paths, for hosting)
  - <scratchpad>/cinderplot-preview.html   (self-contained, images inlined)

Run from the cinderplot-examples repo root:  python3 gallery/cinderplot/build.py
"""
import base64, html, pathlib, subprocess, os

ROOT = pathlib.Path(__file__).resolve().parents[2]      # cinderplot-examples/
FIGS = ROOT / "gallery" / "cinderplot" / "figs"
BIN  = "/Users/zhouw3/repo/cinderplot/cinderplot"
PREVIEW = "/private/tmp/claude-501/-Users-zhouw3-repo-plottest/f1bf5dc3-2755-4195-84bf-ef86de45870a/scratchpad/cinderplot-preview.html"

# slug, title, cinderplot DSL expr, ggplot2 expression (runs *and* displays)
VARIANTS = [
    ("basic", "Basic",
     "data/mtcars.csv + aes(wt, mpg) + geom_point()",
     "ggplot(mtcars, aes(wt, mpg)) + geom_point()"),
    ("custom", "Custom colour",
     'data/mtcars.csv + aes(wt, mpg) + geom_point(color="#69b3a2")',
     'ggplot(mtcars, aes(wt, mpg)) + geom_point(color = "#69b3a2")'),
    ("group-cyl", "Colour by group",
     "data/mtcars.csv + aes(wt, mpg, colour=factor(cyl)) + geom_point()",
     "ggplot(mtcars, aes(wt, mpg, colour = factor(cyl))) + geom_point()"),
    ("group-gear", "Groups, other axes",
     "data/mtcars.csv + aes(hp, mpg, colour=factor(gear)) + geom_point()",
     "ggplot(mtcars, aes(hp, mpg, colour = factor(gear))) + geom_point()"),
    ("continuous", "Continuous colour",
     'data/mtcars.csv + aes(wt, mpg, colour=hp) + geom_point() + scale_colour_gradient(low="#132b43", high="#56b1f7")',
     'ggplot(mtcars, aes(wt, mpg, colour = hp)) + geom_point() +\n  scale_colour_gradient(low = "#132b43", high = "#56b1f7")'),
    ("logx", "Log x-axis",
     "data/mtcars.csv + aes(hp, mpg) + geom_point() + scale_x_log10()",
     "ggplot(mtcars, aes(hp, mpg)) + geom_point() + scale_x_log10()"),
    ("iris-sepal", "Iris · sepals",
     "data/iris.csv + aes(Sepal.Length, Sepal.Width, colour=Species) + geom_point()",
     "ggplot(iris, aes(Sepal.Length, Sepal.Width, colour = Species)) + geom_point()"),
    ("iris-petal", "Iris · petals",
     "data/iris.csv + aes(Petal.Length, Petal.Width, colour=Species) + geom_point()",
     "ggplot(iris, aes(Petal.Length, Petal.Width, colour = Species)) + geom_point()"),
]

def render():
    FIGS.mkdir(parents=True, exist_ok=True)
    # 1. ggplot references via one R script (pdf device; no cairo/X11 needed)
    r = ["suppressMessages(library(ggplot2))",
         "iris <- read.csv('data/iris.csv'); mtcars <- read.csv('data/mtcars.csv')"]
    for slug, _t, _cp, rc in VARIANTS:
        r.append(f"ggsave('gallery/cinderplot/figs/{slug}-gg.pdf', {rc}, width=6, height=4)")
    (ROOT / "gallery/cinderplot/gen.R").write_text("\n".join(r) + "\n")
    subprocess.run(["Rscript", "gallery/cinderplot/gen.R"], cwd=ROOT, check=True,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    # 2. rasterise ggplot PDFs, render cinderplot SVGs
    for slug, _t, cp, _rc in VARIANTS:
        subprocess.run(["pdftoppm", "-r", "150", "-png", "-singlefile",
                        f"gallery/cinderplot/figs/{slug}-gg.pdf",
                        f"gallery/cinderplot/figs/{slug}-gg"], cwd=ROOT, check=True)
        (FIGS / f"{slug}-gg.pdf").unlink(missing_ok=True)   # keep only PNG
        subprocess.run([BIN, cp, "-o", f"gallery/cinderplot/figs/{slug}-cp.svg"],
                       cwd=ROOT, check=True, stdout=subprocess.DEVNULL)

def esc(s):  # escape for HTML text/pre
    return html.escape(s)

def cards(src):
    """src(slug, ext) -> the value for an <img src>. Returns cards HTML."""
    out = []
    for slug, title, cp, rc in VARIANTS:
        cp_cmd = "cinderplot '" + cp.replace(" + ", "\n  + ") + "' \\\n  -o out.svg"
        out.append(f'''      <figure class="card">
        <div class="stage" tabindex="0" aria-label="{esc(title)} scatterplot; hover or focus for code">
          <img data-v="cp" src="{src(slug,'cp.svg')}" alt="{esc(title)} — cinderplot">
          <img data-v="r" src="{src(slug,'gg.png')}" alt="{esc(title)} — ggplot2" hidden>
          <div class="overlay">
            <pre data-v="cp"><span class="c"># cinderplot</span>
{esc(cp_cmd)}</pre>
            <pre data-v="r"><span class="c"># R + ggplot2</span>
{esc(rc)}</pre>
          </div>
        </div>
        <figcaption>{esc(title)}</figcaption>
      </figure>''')
    return "\n".join(out)

STYLE = """<style>
  :root {
    --ground:#FBFAF8; --card:#F4F0EA; --ink:#221D1A; --muted:#6E645D;
    --line:#E7E1D9; --ember:#D6532A; --ember-soft:rgba(214,83,42,.12);
    --code-ink:#EFE9E2; --code-dim:#C9A98F;
    --sans: system-ui,-apple-system,"Segoe UI",Helvetica,Arial,sans-serif;
    --mono: ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;
  }
  @media (prefers-color-scheme: dark) { :root {
    --ground:#16120F; --card:#201A16; --ink:#F1EBE3; --muted:#A89C93;
    --line:#302822; --ember:#F0693B; --ember-soft:rgba(240,105,59,.16); --code-dim:#C9A98F; } }
  :root[data-theme="light"] {
    --ground:#FBFAF8; --card:#F4F0EA; --ink:#221D1A; --muted:#6E645D;
    --line:#E7E1D9; --ember:#D6532A; --ember-soft:rgba(214,83,42,.12); --code-dim:#C9A98F; }
  :root[data-theme="dark"] {
    --ground:#16120F; --card:#201A16; --ink:#F1EBE3; --muted:#A89C93;
    --line:#302822; --ember:#F0693B; --ember-soft:rgba(240,105,59,.16); --code-dim:#C9A98F; }
  * { box-sizing:border-box; }
  body { margin:0; background:var(--ground); color:var(--ink); font-family:var(--sans);
         font-size:16px; line-height:1.6; -webkit-font-smoothing:antialiased; }
  .wrap { max-width:1080px; margin:0 auto; padding:0 24px; }
  header.site { border-bottom:1px solid var(--line); }
  header.site .wrap { display:flex; align-items:center; gap:10px; height:56px; }
  .mark { font-family:var(--mono); font-weight:600; font-size:15px; display:flex; align-items:center; gap:8px; }
  .ember { width:10px; height:10px; border-radius:2px; background:var(--ember); box-shadow:0 0 10px var(--ember); }
  .mark .sub { color:var(--muted); font-weight:400; }
  main { padding:44px 0 96px; }
  .eyebrow { font-family:var(--mono); font-size:12px; letter-spacing:.14em; text-transform:uppercase;
             color:var(--ember); margin:0 0 14px; }
  h1 { font-size:38px; line-height:1.08; letter-spacing:-.025em; margin:0 0 14px; text-wrap:balance; }
  .lede { color:var(--muted); font-size:19px; line-height:1.5; margin:0 0 26px; max-width:66ch; }
  .lede b { color:var(--ink); font-weight:600; }
  .toolbar { display:flex; align-items:center; gap:12px; margin:0 0 22px; }
  .toolbar .lbl { font-family:var(--mono); font-size:12px; letter-spacing:.03em; color:var(--muted); }
  .tabs { display:inline-flex; gap:3px; padding:3px; background:var(--card);
          border:1px solid var(--line); border-radius:9px; }
  .tab { font-family:var(--mono); font-size:12px; color:var(--muted); background:transparent; border:0;
         padding:5px 13px; border-radius:6px; cursor:pointer; transition:background .15s ease, color .15s ease; }
  .tab:hover { color:var(--ink); }
  .tab.active { background:var(--ember); color:#fff; }
  .cards { display:grid; grid-template-columns:repeat(4,1fr); gap:16px; }
  @media (max-width:900px){ .cards{ grid-template-columns:repeat(2,1fr); } }
  @media (max-width:520px){ .cards{ grid-template-columns:1fr; } }
  .card { margin:0; border:1px solid var(--line); border-radius:12px; overflow:hidden; background:var(--card);
          transition:border-color .18s ease, transform .18s ease; }
  .card:hover { border-color:var(--ember); transform:translateY(-2px); }
  .stage { position:relative; background:#fff; outline:none; }
  .stage img { display:block; width:100%; height:auto; }
  .stage img[hidden] { display:none; }
  .overlay { position:absolute; inset:0; padding:12px; background:rgba(24,18,14,.9);
             opacity:0; transition:opacity .16s ease; pointer-events:none;
             display:flex; align-items:center; }
  .stage:hover .overlay, .stage:focus-visible .overlay { opacity:1; pointer-events:auto; }
  .overlay pre { margin:0; width:100%; color:var(--code-ink); font-family:var(--mono);
                 font-size:10.5px; line-height:1.5; white-space:pre-wrap; word-break:break-word; }
  .overlay pre[hidden] { display:none; }
  .overlay .c { color:var(--code-dim); }
  figcaption { font-family:var(--mono); font-size:12px; color:var(--ink); padding:9px 12px;
               border-top:1px solid var(--line); background:var(--ground); }
  .note { border-left:3px solid var(--ember); background:var(--card); padding:14px 18px;
          border-radius:0 10px 10px 0; margin:34px 0 0; }
  .note b { color:var(--ember); }
  footer { color:var(--muted); font-family:var(--mono); font-size:12.5px; border-top:1px solid var(--line);
           margin-top:40px; padding-top:20px; }
  footer a { color:var(--ember); text-decoration:none; }
  .stage:focus-visible { outline:2px solid var(--ember); outline-offset:-2px; }
  @media (prefers-reduced-motion: reduce){ .card{ transition:none; } .card:hover{ transform:none; } }
</style>"""

BODY = """<header class="site">
  <div class="wrap"><span class="mark"><span class="ember"></span>cinderplot <span class="sub">/ gallery</span></span></div>
</header>
<main>
  <div class="wrap">
    <p class="eyebrow">Gallery › Scatterplot</p>
    <h1>Scatterplot</h1>
    <p class="lede">
      The scatterplot, drawn __N__ ways — grouped, coloured, log-scaled, across datasets. Every figure is
      rendered by <b>cinderplot</b> straight from a CSV, no R at plot time. <b>Hover any plot for the command;</b>
      flip the toggle to see the R original it reproduces.
    </p>
    <div class="toolbar">
      <span class="lbl">drawn with</span>
      <div class="tabs" role="tablist" aria-label="Drawn with">
        <button class="tab active" data-t="cp" role="tab" aria-selected="true">cinderplot</button>
        <button class="tab" data-t="r" role="tab" aria-selected="false">R · ggplot2</button>
      </div>
    </div>
    <div class="cards">
__CARDS__
    </div>
    <div class="note"><b>Same figures, no R.</b> cinderplot reproduces ggplot2's <code>theme_gray</code> —
      panel, gridlines, hue palette, axis breaks, legends — from one C binary that reads the CSV and writes
      PDF or SVG in milliseconds.</div>
    <footer>data: mtcars.csv, iris.csv &nbsp;·&nbsp; rebuild: gallery/cinderplot/build.py &nbsp;·&nbsp;
      <a href="https://github.com/zhou-lab/cinderplot">github.com/zhou-lab/cinderplot</a></footer>
  </div>
</main>
<script>
(function () {
  var tabs = [].slice.call(document.querySelectorAll('.tab'));
  var items = [].slice.call(document.querySelectorAll('[data-v]'));
  function set(v) {
    items.forEach(function (el) { el.hidden = (el.dataset.v !== v); });
    tabs.forEach(function (b) { var on = b.dataset.t === v;
      b.classList.toggle('active', on); b.setAttribute('aria-selected', on ? 'true' : 'false'); });
  }
  tabs.forEach(function (b) { b.addEventListener('click', function () { set(b.dataset.t); }); });
})();
</script>"""

def build_html():
    n_words = {8:"eight",7:"seven",6:"six",5:"five"}.get(len(VARIANTS), str(len(VARIANTS)))
    body = BODY.replace("__N__", n_words)
    # hosted page: relative asset paths
    page = ("<!doctype html>\n<html lang=\"en\">\n<head>\n<meta charset=\"utf-8\">\n"
            "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\n"
            "<title>Scatterplot — Cinderplot Gallery</title>\n" + STYLE + "\n</head>\n<body>\n"
            + body.replace("__CARDS__", cards(lambda s,e: f"cinderplot/figs/{s}-{e}"))
            + "\n</body>\n</html>\n")
    (ROOT / "gallery" / "cinderplot.html").write_text(page)
    # self-contained preview: inline every asset as a data URI
    def datauri(slug, ext):
        p = FIGS / f"{slug}-{ext}"
        b = base64.b64encode(p.read_bytes()).decode()
        mime = "image/svg+xml" if ext.endswith("svg") else "image/png"
        return f"data:{mime};base64,{b}"
    preview = STYLE + "\n" + body.replace("__CARDS__", cards(datauri))
    pathlib.Path(PREVIEW).write_text(preview)
    print("wrote gallery/cinderplot.html and preview")

if __name__ == "__main__":
    render()
    build_html()

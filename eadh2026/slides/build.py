#!/usr/bin/env python
"""Build the EADH 2026 talk deck from the RUG Janina template."""
import os, re, shutil, subprocess, sys, zipfile
from xml.sax.saxutils import escape

SK = "/Users/fedor/Library/Application Support/Claude/local-agent-mode-sessions/skills-plugin/a19e01fc-4b26-4783-9aab-adce999fdd39/6aa349a6-b947-479d-9d1c-5b0c6cb6e3f0/skills/pptx/scripts"
HERE = os.path.dirname(os.path.abspath(__file__))
U = os.path.join(HERE, "unpacked")
OUT = os.path.join(HERE, "eadh2026_talk.pptx")
NOTES_MD = os.path.join(HERE, "..", "talk_speaker_notes.md")

RED, BLACK, GREY, DGREY, BEIGE, WHITE = "FF0000", "191919", "595959", "434343", "EFEDDE", "FFFFFF"
T_FONT, B_FONT, N_FONT = "Bebas Neue", "Barlow", "Abril Fatface"

def E(v): return int(round(v * 914400))
_id = [100]
def nid():
    _id[0] += 1; return _id[0]

# ---------- XML builders ----------
def rpr(f=B_FONT, sz=12, b=False, i=False, color=BLACK, caps=False):
    return (f'<a:rPr lang="en" sz="{int(sz*100)}" b="{1 if b else 0}" i="{1 if i else 0}"'
            f'{" cap=\"all\"" if caps else ""}><a:solidFill><a:srgbClr val="{color}"/></a:solidFill>'
            f'<a:latin typeface="{f}"/><a:ea typeface="{f}"/><a:cs typeface="{f}"/><a:sym typeface="{f}"/></a:rPr>')

def run(text, **kw):
    return f'<a:r>{rpr(**kw)}<a:t xml:space="preserve">{escape(text)}</a:t></a:r>'

def para(runs, algn="l", spc_after=0, spc_before=0, bullet=None, line=100, marL=0, indent=0):
    ppr = f'<a:pPr algn="{algn}" marL="{marL}" indent="{indent}"><a:lnSpc><a:spcPct val="{line*1000}"/></a:lnSpc>'
    ppr += f'<a:spcBef><a:spcPts val="{int(spc_before*100)}"/></a:spcBef><a:spcAft><a:spcPts val="{int(spc_after*100)}"/></a:spcAft>'
    if bullet:
        ppr += f'<a:buClr><a:srgbClr val="{RED}"/></a:buClr><a:buSzPct val="90000"/><a:buFont typeface="Arial"/><a:buChar char="{bullet}"/>'
    else:
        ppr += '<a:buNone/>'
    ppr += '</a:pPr>'
    return f'<a:p>{ppr}{"".join(runs)}</a:p>'

def textbox(x, y, w, h, paras, anchor="t", ins=0.0, name="text"):
    i = E(ins)
    return (f'<p:sp><p:nvSpPr><p:cNvPr id="{nid()}" name="{name}"/><p:cNvSpPr txBox="1"/><p:nvPr/></p:nvSpPr>'
            f'<p:spPr><a:xfrm><a:off x="{E(x)}" y="{E(y)}"/><a:ext cx="{E(w)}" cy="{E(h)}"/></a:xfrm>'
            f'<a:prstGeom prst="rect"><a:avLst/></a:prstGeom><a:noFill/></p:spPr>'
            f'<p:txBody><a:bodyPr wrap="square" lIns="{i}" tIns="{i}" rIns="{i}" bIns="{i}" anchor="{anchor}"><a:noAutofit/></a:bodyPr>'
            f'<a:lstStyle/>{"".join(paras)}</p:txBody></p:sp>')

def rect(x, y, w, h, fill=RED, alpha=None, line=None, geom="rect", name="shape"):
    a = f'<a:alpha val="{int(alpha*1000)}"/>' if alpha is not None else ''
    ln = (f'<a:ln w="9525"><a:solidFill><a:srgbClr val="{line}"/></a:solidFill></a:ln>' if line else '<a:ln><a:noFill/></a:ln>')
    fl = f'<a:solidFill><a:srgbClr val="{fill}">{a}</a:srgbClr></a:solidFill>' if fill else '<a:noFill/>'
    return (f'<p:sp><p:nvSpPr><p:cNvPr id="{nid()}" name="{name}"/><p:cNvSpPr/><p:nvPr/></p:nvSpPr>'
            f'<p:spPr><a:xfrm><a:off x="{E(x)}" y="{E(y)}"/><a:ext cx="{E(w)}" cy="{E(h)}"/></a:xfrm>'
            f'<a:prstGeom prst="{geom}"><a:avLst/></a:prstGeom>{fl}{ln}</p:spPr>'
            f'<p:txBody><a:bodyPr/><a:lstStyle/><a:p><a:endParaRPr/></a:p></p:txBody></p:sp>')

def pic(rid, x, y, w, h, name="picture"):
    return (f'<p:pic><p:nvPicPr><p:cNvPr id="{nid()}" name="{name}"/><p:cNvPicPr><a:picLocks noChangeAspect="1"/></p:cNvPicPr><p:nvPr/></p:nvPicPr>'
            f'<p:blipFill><a:blip r:embed="{rid}"/><a:stretch><a:fillRect/></a:stretch></p:blipFill>'
            f'<p:spPr><a:xfrm><a:off x="{E(x)}" y="{E(y)}"/><a:ext cx="{E(w)}" cy="{E(h)}"/></a:xfrm>'
            f'<a:prstGeom prst="rect"><a:avLst/></a:prstGeom><a:ln w="6350"><a:solidFill><a:srgbClr val="{DGREY}"/></a:solidFill></a:ln></p:spPr></p:pic>')

def sldnum():
    return ('<p:sp><p:nvSpPr><p:cNvPr id="%d" name="slide number"/><p:cNvSpPr txBox="1"/><p:nvPr><p:ph idx="12" type="sldNum"/></p:nvPr></p:nvSpPr>'
            '<p:spPr><a:xfrm><a:off x="8250500" y="4608500"/><a:ext cx="695100" cy="279300"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom></p:spPr>'
            '<p:txBody><a:bodyPr anchor="ctr"/><a:lstStyle/><a:p><a:pPr algn="ctr"/><a:fld id="{00000000-1234-1234-1234-123412341234}" type="slidenum">'
            f'<a:rPr lang="en" sz="900"><a:solidFill><a:srgbClr val="{RED}"/></a:solidFill><a:latin typeface="{B_FONT}"/></a:rPr><a:t>‹#›</a:t></a:fld></a:p></p:txBody></p:sp>') % nid()

def title(parts, y=0.5, h=0.62, sz=28):
    """parts: list of (text, is_red)"""
    runs = [run(t, f=T_FONT, sz=sz, color=RED if r else BLACK) for t, r in parts]
    return textbox(0.94, y, 8.12, h, [para(runs, algn="ctr")], anchor="ctr", name="title")

def cell(runs_or_text, algn="l", fill=None, sz=11, b=False, color=BLACK, f=B_FONT, i=False, margin=0.05, hdr=False):
    if isinstance(runs_or_text, str):
        runs = [run(runs_or_text, f=f, sz=sz, b=b, color=color, i=i)]
    else:
        runs = runs_or_text
    m = E(margin)
    fl = f'<a:solidFill><a:srgbClr val="{fill}"/></a:solidFill>' if fill else '<a:noFill/>'
    bord = ''.join(f'<a:ln{s} w="6350"><a:solidFill><a:srgbClr val="BFBFBF"/></a:solidFill></a:ln{s}>' for s in ("L", "R", "T", "B"))
    if hdr:
        bord = ''.join(f'<a:ln{s} w="6350"><a:noFill/></a:ln{s}>' for s in ("L", "R", "T")) + f'<a:lnB w="19050"><a:solidFill><a:srgbClr val="{BLACK}"/></a:solidFill></a:lnB>'
    return (f'<a:tc><a:txBody><a:bodyPr/><a:lstStyle/>{para(runs, algn=algn)}</a:txBody>'
            f'<a:tcPr marL="{m}" marR="{m}" marT="{E(0.03)}" marB="{E(0.03)}" anchor="ctr">{bord}{fl}</a:tcPr></a:tc>')

def table(x, y, col_w, row_h, rows, name="table"):
    """rows: list of lists of <a:tc> strings (from cell())."""
    grid = ''.join(f'<a:gridCol w="{E(w)}"/>' for w in col_w)
    trs = ''
    for r, cells in enumerate(rows):
        rh = row_h[r] if isinstance(row_h, list) else row_h
        trs += f'<a:tr h="{E(rh)}">{"".join(cells)}</a:tr>'
    tot_h = sum(row_h) if isinstance(row_h, list) else row_h * len(rows)
    return (f'<p:graphicFrame><p:nvGraphicFramePr><p:cNvPr id="{nid()}" name="{name}"/><p:cNvGraphicFramePr><a:graphicFrameLocks noGrp="1"/></p:cNvGraphicFramePr><p:nvPr/></p:nvGraphicFramePr>'
            f'<p:xfrm><a:off x="{E(x)}" y="{E(y)}"/><a:ext cx="{E(sum(col_w))}" cy="{E(tot_h)}"/></p:xfrm>'
            f'<a:graphic><a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/table"><a:tbl><a:tblPr/><a:tblGrid>{grid}</a:tblGrid>{trs}</a:tbl></a:graphicData></a:graphic></p:graphicFrame>')

SLD_HEAD = ('<?xml version="1.0" encoding="UTF-8" standalone="yes"?><p:sld xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" '
            'xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main">'
            '<p:cSld><p:spTree><p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="0" cy="0"/><a:chOff x="0" y="0"/><a:chExt cx="0" cy="0"/></a:xfrm></p:grpSpPr>')
SLD_TAIL = '</p:spTree></p:cSld><p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sld>'

def write_slide(n, shapes):
    with open(f"{U}/ppt/slides/slide{n}.xml", "w") as f:
        f.write(SLD_HEAD + "".join(shapes) + sldnum() + SLD_TAIL)

def add_image_rel(n, src, media_name):
    shutil.copy(src, f"{U}/ppt/media/{media_name}")
    rels = f"{U}/ppt/slides/_rels/slide{n}.xml.rels"
    x = open(rels).read()
    ids = [int(m) for m in re.findall(r'Id="rId(\d+)"', x)]
    rid = f"rId{max(ids)+1 if ids else 1}"
    x = x.replace("</Relationships>", f'<Relationship Id="{rid}" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/image" Target="../media/{media_name}"/></Relationships>')
    open(rels, "w").write(x)
    return rid

def add_slide(layout):
    out = subprocess.run([sys.executable, f"{SK}/add_slide.py", U, layout], capture_output=True, text=True, check=True)
    m = re.search(r"slide(\d+)\.xml", out.stdout); return int(m.group(1))

# ---------- speaker notes ----------
def load_notes():
    md = open(NOTES_MD).read()
    notes = {}
    for m in re.finditer(r"^## (\d+) · .*?$(.*?)(?=^## |^---\s*$(?=\n\n## Q&A)|\Z)", md, re.S | re.M):
        n = int(m.group(1)); body = m.group(2)
        body = re.sub(r"\*\*On slide:\*\*.*?\n\n", "", body, count=1, flags=re.S)
        body = body.replace("---", "").strip()
        body = re.sub(r"\*\*(.*?)\*\*", r"\1", body); body = re.sub(r"\*(.*?)\*", r"\1", body)
        body = re.sub(r"`(.*?)`", r"\1", body)
        paras = [re.sub(r"\s*\n\s*", " ", p).strip() for p in body.split("\n\n") if p.strip()]
        notes[n] = paras
    return notes

def write_notes(n, paras):
    tmpl = open(f"{U}/ppt/notesSlides/notesSlide1.xml").read() if n == 1 else open(f"{HERE}/notes_template.xml").read()
    body = "".join(f'<a:p><a:pPr marL="0" indent="0"><a:spcAft><a:spcPts val="600"/></a:spcAft><a:buNone/></a:pPr><a:r><a:rPr lang="en" sz="1200"/><a:t xml:space="preserve">{escape(p)}</a:t></a:r></a:p>' for p in paras)
    x = re.sub(r'(<p:ph idx="1" type="body"/>.*?<a:lstStyle/>).*?(</p:txBody>)', lambda m: m.group(1) + body + m.group(2), tmpl, count=1, flags=re.S)
    open(f"{U}/ppt/notesSlides/notesSlide{n}.xml", "w").write(x)
    open(f"{U}/ppt/notesSlides/_rels/notesSlide{n}.xml.rels", "w").write(
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
        '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/notesMaster" Target="../notesMasters/notesMaster1.xml"/>'
        f'<Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slide" Target="../slides/slide{n}.xml"/></Relationships>')
    if n != 1:
        rels = f"{U}/ppt/slides/_rels/slide{n}.xml.rels"; x = open(rels).read()
        ids = [int(m) for m in re.findall(r'Id="rId(\d+)"', x)]
        x = x.replace("</Relationships>", f'<Relationship Id="rId{max(ids)+1}" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/notesSlide" Target="../notesSlides/notesSlide{n}.xml"/></Relationships>')
        open(rels, "w").write(x)
        ct = f"{U}/[Content_Types].xml"; c = open(ct).read()
        c = c.replace("</Types>", f'<Override ContentType="application/vnd.openxmlformats-officedocument.presentationml.notesSlide+xml" PartName="/ppt/notesSlides/notesSlide{n}.xml"/></Types>')
        open(ct, "w").write(c)

# ---------- build ----------
def reset():
    if os.path.exists(U): shutil.rmtree(U)
    zipfile.ZipFile(f"{HERE}/template.pptx").extractall(U)
    # keep a clean notes template (slide1 notes, before we fill it)
    shutil.copy(f"{U}/ppt/notesSlides/notesSlide1.xml", f"{HERE}/notes_template.xml")

def body(text, sz=12, color=BLACK, b=False, i=False, f=B_FONT):
    return run(text, f=f, sz=sz, color=color, b=b, i=i)

def bullets(items, sz=11.5, after=5, color=BLACK):
    return [para([body(t, sz=sz, color=color)], bullet="■", marL=E(0.22), indent=-E(0.22), spc_after=after) for t in items]

def slide1():
    L = f"{U}/ppt/slideLayouts/slideLayout1.xml"; lx = open(L).read()
    lx = re.sub(r'<p:pic><p:nvPicPr><p:cNvPr id="\d+" name="RUG logo"/>.*?</p:pic>', "", lx, count=1, flags=re.S); open(L, "w").write(lx)
    p = f"{U}/ppt/slides/slide1.xml"; x = open(p).read()
    x = x.replace("<a:t>Master Open Door Day 2026</a:t>", "<a:t>EADH 2026 · University of Groningen</a:t>")
    x = x.replace("<a:t>Master’s </a:t>", "<a:t>Geographic citation</a:t>")
    x = x.replace("<a:t>Digital humanities</a:t>", "<a:t>insularity in DH</a:t>")
    x = x.replace('<a:srcRect b="3153" l="26403" r="24999" t="3563"/>', '<a:srcRect b="0" l="0" r="0" t="0"/>')
    open(p, "w").write(x)
    shutil.copy(f"{HERE}/img/title_network.png", f"{U}/ppt/media/title_network.png")
    r = f"{U}/ppt/slides/_rels/slide1.xml.rels"; y = open(r).read().replace("../media/image22.png", "../media/title_network.png"); open(r, "w").write(y)

def slide2():
    n = add_slide("slideLayout14.xml")
    S = [title([("Does DH cite ", 0), ("globally", 1), ("?", 0)])]
    S.append(textbox(0.9, 1.25, 8.2, 0.85, [para([body("Do DH scholars cite their own country more than they should — and is that changing?", sz=19, color=RED, b=True, i=True)], algn="ctr")], anchor="ctr"))
    cards = [("Fiormonte", "2012", "Anglophone and Western-European power structures shape DH scholarship"),
             ("Galina Russell", "2014", "Geographic and linguistic unevenness of DH research output"),
             ("Risam", "2019", "Digital knowledge production reproduces global inequality")]
    for k, (nm, yr, txt) in enumerate(cards):
        x0 = 0.85 + k * 2.85
        S.append(rect(x0, 2.45, 0.5, 0.07, fill=RED))
        S.append(textbox(x0, 2.6, 2.55, 1.35, [
            para([run(nm, f=T_FONT, sz=17, color=BLACK), run("  " + yr, f=B_FONT, sz=11, color=RED, b=True, i=True)], spc_after=4),
            para([body(txt, sz=11, color=DGREY)])]))
    S.append(textbox(0.85, 4.05, 8.0, 0.7, [
        para([body("Evidence so far: qualitative, or counts of conference submissions. ", sz=11.5, color=BLACK),
              body("Two bibliometric studies — Tang et al. 2017, Spinaci et al. 2022 — neither at citation level.", sz=11.5, color=BLACK, b=True)])], anchor="ctr"))
    write_slide(n, S); return n

def slide3():
    n = add_slide("slideLayout13.xml")
    S = [title([("Insularity in ", 0), ("one", 1), (" slide", 0)])]
    S.append(textbox(0.6, 1.2, 4.7, 0.95, [para([body("A citation is ", sz=14), body("insular", sz=14, b=True, color=RED),
        body(" when the citing paper and the cited paper share at least one author country.", sz=14)])]))
    # worked example
    S.append(rect(0.6, 2.35, 1.3, 0.55, fill=WHITE, line=BLACK))
    S.append(textbox(0.6, 2.35, 1.3, 0.55, [para([run("DE · FR", f=T_FONT, sz=16)], algn="ctr")], anchor="ctr"))
    S.append(textbox(0.6, 2.92, 1.3, 0.3, [para([body("citing", sz=9, color=GREY, i=True)], algn="ctr")]))
    S.append(rect(2.05, 2.5, 0.75, 0.25, fill=RED, geom="rightArrow"))
    S.append(rect(2.95, 2.35, 1.3, 0.55, fill=WHITE, line=BLACK))
    S.append(textbox(2.95, 2.35, 1.3, 0.55, [para([run("US · DE", f=T_FONT, sz=16)], algn="ctr")], anchor="ctr"))
    S.append(textbox(2.95, 2.92, 1.3, 0.3, [para([body("cited", sz=9, color=GREY, i=True)], algn="ctr")]))
    S.append(textbox(4.4, 2.35, 1.0, 0.55, [para([run("insular", f=T_FONT, sz=14, color=RED)], algn="l")], anchor="ctr"))
    S.append(textbox(0.6, 3.3, 4.7, 0.55, [para([body("“Any overlap” rule. The stricter majority rule (> 50 % of citing countries) tells the same story at lower levels.", sz=10, color=GREY, i=True)])]))
    # right column
    S.append(textbox(5.7, 1.2, 3.7, 0.7, [para([body("Raw self-citation is meaningless alone: big producers cite themselves because there is more to cite. So compare with what chance predicts —", sz=11, color=DGREY)])]))
    S.append(textbox(5.7, 1.95, 3.7, 0.4, [para([body("expected", sz=12, b=True, color=BLACK), body(" = a country’s share of everything cited", sz=12, color=BLACK)])]))
    for k, (lbl, expl) in enumerate([("Excess", "observed − expected, in percentage points"), ("Ratio", "observed ÷ expected — how many times more insular than chance")]):
        y0 = 2.5 + k * 0.85
        S.append(rect(5.7, y0 + 0.08, 0.09, 0.5, fill=RED))
        S.append(textbox(5.95, y0, 3.45, 0.7, [para([run(lbl, f=T_FONT, sz=20, color=RED)], spc_after=1), para([body(expl, sz=11)])]))
    S.append(textbox(2.05, 4.25, 7.3, 0.5, [para([body("Significance: 1,000-round permutation — shuffle country labels on the cited side, keep the citation graph, ask whether the real value is extreme.", sz=10, color=GREY)])], anchor="ctr"))
    write_slide(n, S); return n

def slide4():
    n = add_slide("slideLayout5.xml")
    S = [title([("Two ", 0), ("corpora", 1)])]
    cols = [("01", "Journals", [
                "Spinaci et al. list — 19 Exclusively-DH journals — plus “digital humanities” in any title or abstract",
                "OpenAlex API → ~17,600 works, 2000–2025",
                "Every reference followed; cited-work countries fetched",
                "58,655 citation pairs with country on both ends",
                "63 countries with ≥ 100 citations"]),
            ("02", "ADHO conference", [
                "Index of DH Conferences (CMU): abstracts and affiliations, but no reference links",
                "Reference strings extracted from full text, parsed with AnyStyle",
                "Matched offline against an OpenAlex snapshot: DOI → exact title → fuzzy ≥ .95",
                "11,645 resolved (27 %) → ~5,000 citation edges",
                "ADHO annual conference and its predecessors only"])]
    for k, (num, lbl, items) in enumerate(cols):
        x0 = 0.65 + k * 4.55
        S.append(textbox(x0, 1.15, 0.9, 0.7, [para([run(num, f=N_FONT, sz=34, color=RED, i=True)])], anchor="ctr"))
        S.append(textbox(x0 + 0.95, 1.15, 3.1, 0.7, [para([run(lbl, f=T_FONT, sz=20, color=BLACK)])], anchor="ctr"))
        S.append(rect(x0 + 0.98, 1.82, 1.1, 0.06, fill=RED))
        S.append(textbox(x0, 2.0, 4.05, 2.25, bullets(items, sz=11, after=6)))
    S.append(rect(4.97, 1.25, 0.008, 2.9, fill="BFBFBF"))
    S.append(textbox(0.65, 4.3, 8.6, 0.45, [para([body("Same measures. Same null model. Applied to both.", sz=14, color=RED, b=True, i=True)], algn="ctr")], anchor="ctr"))
    write_slide(n, S); return n

def slide5():
    n = add_slide("slideLayout13.xml")
    S = [title([("Everyone", 1), (" is insular", 0)])]
    hdr = ["Country", "N cit.", "Observed", "Expected", "Excess", "Ratio"]
    rows = [["US", "9,646", ".60", ".29", "+31 pp", "2.1×"],
            ["GB", "8,111", ".38", ".12", "+27 pp", "3.3×"],
            ["CN", "6,449", ".30", ".04", "+26 pp", "7.4×"],
            ["FR", "3,294", ".36", ".03", "+32 pp", "10.7×"],
            ["FI", "1,489", ".31", ".01", "+30 pp", "31.2×"],
            ["AT", "1,414", ".28", ".01", "+27 pp", "27.9×"]]
    hot = {("US", 4), ("FR", 4), ("FI", 5), ("AT", 5)}
    trs = [[cell(h, algn="l" if j == 0 else "r", f=T_FONT, sz=12, hdr=True) for j, h in enumerate(hdr)]]
    for r in rows:
        tr = []
        for j, v in enumerate(r):
            red = (r[0], j) in hot
            tr.append(cell(v, algn="l" if j == 0 else "r", sz=11.5, b=(j == 0 or red), color=RED if red else BLACK, f=T_FONT if j == 0 else B_FONT))
        trs.append(tr)
    S.append(table(0.6, 1.2, [0.95, 0.95, 1.0, 1.0, 1.0, 0.85], 0.35, trs))
    S.append(textbox(6.6, 1.25, 2.8, 0.8, [para([run("30 / 30", f=N_FONT, sz=36, color=RED, i=True)], algn="l")], anchor="ctr"))
    S.append(textbox(6.6, 2.05, 2.8, 0.7, [para([run("countries above chance", f=T_FONT, sz=15, color=BLACK)]), para([body("p < .001 · all with ≥ 100 citations", sz=10, color=GREY)])]))
    S.append(textbox(6.6, 2.85, 2.8, 0.6, [para([body("Structural, not a US quirk.", sz=12, color=RED, b=True, i=True)])]))
    S.append(textbox(2.0, 3.95, 7.4, 0.85, [
        para([body("By excess: ", sz=11.5, b=True), body("France and the US lead, 31–32 points above expectation.", sz=11.5)], spc_after=4),
        para([body("By ratio: ", sz=11.5, b=True), body("Finland 31×, Austria 28×, Greece 23× — the US just 2×. Small, cohesive national communities amplify most.", sz=11.5)])]))
    write_slide(n, S); return n

def slide6():
    n = add_slide("slideLayout5.xml")
    rid = add_image_rel(n, f"{HERE}/img/heatmap.png", "heatmap.png")
    S = [title([("Who cites ", 0), ("whom", 1), ("?", 0)])]
    S.append(pic(rid, 0.55, 1.12, 4.93, 3.7))
    S.append(textbox(0.55, 4.84, 4.93, 0.25, [para([body("Cell = observed − expected citation share · top 30 countries · N = 58,655", sz=8, color=GREY)])]))
    items = [("The diagonal", "Red all the way down: every country cites itself above chance."),
             ("The US column", "Mostly blue. Most countries cite the United States below its share — and keep those citations at home."),
             ("Regional blocks", "East Asia top-left; the German-speaking countries and the Netherlands bottom-right.")]
    for k, (h, t) in enumerate(items):
        y0 = 1.2 + k * 1.2
        S.append(rect(5.85, y0 + 0.07, 0.09, 0.42, fill=RED))
        S.append(textbox(6.1, y0, 3.3, 1.1, [para([run(h, f=T_FONT, sz=17, color=BLACK)], spc_after=2), para([body(t, sz=11)])]))
    write_slide(n, S); return n

def slide7():
    n = add_slide("slideLayout5.xml")
    rid = add_image_rel(n, f"{HERE}/img/conf_vs_journal.png", "conf_vs_journal.png")
    S = [title([("Journals open up. The conference ", 0), ("doesn’t", 1), (".", 0)], sz=26)]
    S.append(pic(rid, 0.55, 1.15, 5.9, 3.3))
    S.append(textbox(0.55, 4.5, 5.9, 0.4, [para([body("Any-overlap self-country citation rate by year. Conference yearly n is small — read the level, not the wiggles.", sz=8.5, color=GREY)])]))
    blocks = [("Journals", "42 % → 25 %", "2007 → 2025. Only the US decline is significant on its own (−1 pp / year)."),
              ("ADHO conference", "≈ 42 %, flat", "No trend to find. DHd tracks it at 40 %.")]
    for k, (h, big, t) in enumerate(blocks):
        y0 = 1.2 + k * 1.75
        S.append(textbox(6.7, y0, 2.7, 0.35, [para([run(h, f=T_FONT, sz=15, color=BLACK)])]))
        S.append(textbox(6.7, y0 + 0.35, 2.7, 0.6, [para([run(big, f=N_FONT, sz=24, color=RED, i=True)])], anchor="ctr"))
        S.append(textbox(6.7, y0 + 0.98, 2.7, 0.7, [para([body(t, sz=10, color=DGREY)])]))
    write_slide(n, S); return n

def slide8():
    n = add_slide("slideLayout5.xml")
    S = [title([("Is this ", 0), ("DH", 1), (", or just science?", 0)])]
    S.append(textbox(0.6, 1.1, 8.8, 0.4, [para([body("Benchmark: Wu, Huang, Lu, Saxena & Traag (2026), arXiv 2604.01602 — 39 M OpenAlex publications, 95 countries, 2000–2022", sz=10, color=GREY, i=True)], algn="ctr")], anchor="ctr"))
    hdr = ["", "Wu et al. — all science", "This study — DH", "Verdict"]
    rows = [["Method", "Bayesian gravity model: country-pair preference, net of distance and city volume", "Share-based null model + 1,000-round permutation test", ("Different estimator", GREY)],
            ["Domestic preference", "Strong, every country, persistent 2000–2022", "Strong, every country: 30 / 30, p < .001", ("Agrees", BLACK)],
            ["Orientation to the US", "Most countries cite the US above expectation", "Most countries cite the US below expectation", ("DH deviates", RED)],
            ["Trend", "Distance effect on citation tiny and shrinking; country bias does not fade", "Journals fade, 42 % → 25 %; the conference doesn’t", ("Conference matches; journals don’t", RED)]]
    trs = [[cell(h, f=T_FONT, sz=12, hdr=True) for h in hdr]]
    for r in rows:
        v, c = r[3]
        trs.append([cell(r[0], f=T_FONT, sz=12), cell(r[1], sz=10.5), cell(r[2], sz=10.5), cell(v, f=T_FONT, sz=12, color=c)])
    S.append(table(0.6, 1.55, [1.5, 2.95, 2.95, 1.4], [0.38, 0.62, 0.5, 0.5, 0.62], trs))
    S.append(textbox(0.6, 4.35, 8.8, 0.45, [para([body("Comparable in sign, not in magnitude: a model coefficient versus a share ratio.", sz=12, color=RED, b=True, i=True)], algn="ctr")], anchor="ctr"))
    write_slide(n, S); return n

def slide9():
    n = add_slide("slideLayout5.xml")
    S = [title([("Caveats", 1), (" & next steps", 0)])]
    S.append(rect(9.29, 1.08, 0.71, 1.22, fill=RED))
    S.append(textbox(0.65, 1.2, 4.2, 0.4, [para([run("Caveats", f=T_FONT, sz=18, color=RED)])]))
    S.append(rect(0.65, 1.62, 0.9, 0.06, fill=RED))
    S.append(textbox(0.65, 1.95, 4.2, 2.9, bullets([
        "Conference network is reconstructed: a reference must be parseable, in OpenAlex, and carry country — skews English-language and recent",
        "Per-series is effectively ADHO vs DHd; other regional series resolve to nothing",
        "Keyword search favours work that calls itself DH",
        "Full counting inflates multi-country papers",
        "Country ≠ language ≠ culture"], sz=12.5, after=11)))
    S.append(textbox(5.3, 1.2, 3.8, 0.4, [para([run("Next", f=T_FONT, sz=18, color=RED)])]))
    S.append(rect(5.3, 1.62, 0.9, 0.06, fill=RED))
    S.append(textbox(5.3, 1.95, 3.8, 2.9, bullets([
        "Same pipeline on History, Literature, Sociology, Political Science — is DH distinctive?",
        "Fit Wu et al.’s preference model on the DH corpus: is the US-column difference field or method?",
        "Push conference resolution past 27 %: ~3,000 references sit in the 0.85–0.95 review band"], sz=12.5, after=14)))
    write_slide(n, S); return n

def slide10():
    n = add_slide("slideLayout13.xml")
    S = [title([("Three things to ", 0), ("take home", 1)])]
    items = ["Geographic self-citation in DH is universal and significant — and most amplified in small national communities, not large ones.",
             "DH journals have been shedding it for twenty years: 42 % → 25 %.",
             "The ADHO conference hasn’t: flat at ≈ 42 %."]
    for k, t in enumerate(items):
        y0 = 1.25 + k * 0.85
        S.append(textbox(0.9, y0, 0.95, 0.7, [para([run(f"0{k+1}", f=N_FONT, sz=30, color=RED, i=True)])], anchor="ctr"))
        S.append(textbox(2.0, y0, 6.9, 0.7, [para([body(t, sz=14)])], anchor="ctr"))
    S.append(rect(2.0, 4.05, 7.3, 0.62, fill=RED))
    S.append(textbox(2.15, 4.05, 7.0, 0.62, [para([body("github.com/fedormyskin/OpenAlex-DH-analysis", sz=13, color=WHITE, b=True)], spc_after=1),
                                              para([body("code · data · conference reference-matching pipeline", sz=10, color=WHITE)])], anchor="ctr"))
    write_slide(n, S); return n

def main():
    reset()
    slide1()
    made = [1] + [f() for f in (slide2, slide3, slide4, slide5, slide6, slide7, slide8, slide9, slide10)]
    notes = load_notes()
    for k, n in enumerate(made, start=1):
        write_notes(n, notes.get(k, [""]))
    subprocess.run([sys.executable, f"{SK}/clean.py", U], check=True, capture_output=True)
    if os.path.exists(OUT): os.remove(OUT)
    subprocess.run(["zip", "-Xr", OUT, "."], cwd=U, check=True, capture_output=True)
    print("slides:", made); print("wrote", OUT)

if __name__ == "__main__":
    main()

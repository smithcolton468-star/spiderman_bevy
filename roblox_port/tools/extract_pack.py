"""Unpacks SpiderManData.rbxmx into plain files so the Luau CLI tests can read the same data Studio does.
Text modules ('return [[...]]') -> <path>.txt ; payload folders (001, 002, ...) -> <path>.bin (base64 joined, zstd
decompressed, exactly what Decoder.payload does with EncodingService). Also writes index.txt listing every path."""
import base64, re, sys
from pathlib import Path
from lxml import etree
import zstandard

src, out = Path(sys.argv[1]), Path(sys.argv[2])
out.mkdir(parents=True, exist_ok=True)
tree = etree.parse(str(src), etree.XMLParser(huge_tree=True))
LONG = re.compile(r"^return\s*\[(=*)\[\n?(.*)\]\1\]\s*$", re.S)
STR = re.compile(r'^return\s*"([A-Za-z0-9+/=]*)"\s*$', re.S)

def name_of(item):
    return item.find("Properties/string[@name='Name']").text

def source_of(item):
    return item.find("Properties/ProtectedString[@name='Source']").text or ""

info = None
listing = []
def walk(item, path):
    global info
    cls = item.get("class")
    kids = item.findall("Item")
    name = name_of(item)
    here = path + [name]
    if cls == "Folder" and kids and all(k.get("class") == "ModuleScript" and re.fullmatch(r"\d{3}", name_of(k)) for k in kids):
        parts = sorted(kids, key=name_of)
        raw = b"".join(base64.b64decode(STR.match(source_of(k)).group(1)) for k in parts)
        if info["compression"] == "zstd":
            raw = zstandard.ZstdDecompressor().decompress(raw)
        p = out.joinpath(*here[1:]).with_suffix(".bin") if len(here) > 1 else None
        p = out.joinpath(*here[1:-1], here[-1] + ".bin")
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_bytes(raw)
        listing.append("/".join(here[1:]) + ".bin")
        return
    if cls == "ModuleScript":
        s = source_of(item)
        m = LONG.match(s)
        rel = here[1:]
        if m:
            p = out.joinpath(*rel[:-1], rel[-1] + ".txt")
            p.parent.mkdir(parents=True, exist_ok=True)
            p.write_text(m.group(2))
            listing.append("/".join(rel) + ".txt")
            if name == "PackInfo":
                import json
                info = json.loads(m.group(2))
        else:
            p = out.joinpath(*rel[:-1], rel[-1] + ".luau")
            p.parent.mkdir(parents=True, exist_ok=True)
            p.write_text(s)
            listing.append("/".join(rel) + ".luau")
    for k in kids:
        walk(k, here)

root = tree.getroot().find("Item")
# PackInfo first so the compression is known
for k in root.findall("Item"):
    if name_of(k) == "PackInfo":
        walk(k, [name_of(root)])
for k in root.findall("Item"):
    if name_of(k) != "PackInfo":
        walk(k, [name_of(root)])
(out / "index.txt").write_text("\n".join(listing) + "\n")
print(len(listing), "entries")

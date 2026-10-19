#!/usr/bin/env python3
"""Builds the Roblox port's import files and data pack from this repository's own assets.

    python roblox_port/tools/build_roblox_pack.py [--no-compress] [--luau PATH_TO_LUAU_CLI]

Writes, in roblox_port/:
  import/SpiderMan.glb    the suit and its 212-bone skin, meshes split under Roblox's 20,000-triangle limit, in studs,
                          without animations (the clips travel in the data pack instead)
  import/CityTowers.glb   the seven towers (drawn only: they collide as the layout's boxes)
  import/CityProps.glb    the five car models and the eleven props (drawn, and they collide by their own triangles)
  SpiderManData.rbxmx     a Folder of ModuleScripts: every animation clip bit for bit, the skeleton, the collision
                          triangles, the layout, the tuning, the oracle fixtures, reference poses and the decoder
  manifest.json           what was made, and the numbers the Studio side checks the import against

Needs Python 3.10+ with numpy, Pillow and zstandard. With --luau it also runs the pack's decoder in the Luau CLI on
three clips and a collision model and checks every value against the glTF.
"""
from __future__ import annotations

import argparse
import base64
import hashlib
import io
import json
import math
import struct
import subprocess
import sys
import tempfile
from pathlib import Path
from xml.sax.saxutils import escape

import numpy as np
import zstandard
from PIL import Image

REPO = Path(__file__).resolve().parents[2]
ASSETS = REPO / "assets"
OUT = REPO / "roblox_port"

# Roblox's own convention (the avatar and physics docs): one stud is 0.28 m. The import files are written in studs
# so they import at the right size with the importer's Scale Unit left at Studs; the simulation stays in metres.
STUDS_PER_METRE = 1 / 0.28
TRIANGLE_LIMIT = 20_000  # "Individual meshes can not exceed 20,000 triangles" (Roblox mesh specifications)
SOURCE_LIMIT = 199_000  # Script.Source and string properties stop at 200,000 characters
PART_CHARS = 196_000  # base64 characters per payload ModuleScript: a whole number of quads, under the limit

COMPONENT = {5120: "b", 5121: "B", 5122: "h", 5123: "H", 5125: "I", 5126: "f"}
WIDTH = {"SCALAR": 1, "VEC2": 2, "VEC3": 3, "VEC4": 4, "MAT4": 16}


# glTF reading -------------------------------------------------------------------------------------------------------


class Gltf:
    def __init__(self, path: Path):
        self.path = path
        data = path.read_bytes()
        magic, version, length = struct.unpack_from("<4sII", data, 0)
        assert magic == b"glTF" and version == 2, path
        self.json: dict = {}
        self.bin = b""
        at = 12
        while at < length:
            size, kind = struct.unpack_from("<I4s", data, at)
            chunk = data[at + 8 : at + 8 + size]
            if kind == b"JSON":
                self.json = json.loads(chunk)
            elif kind == b"BIN\0":
                self.bin = chunk
            at += 8 + size

    def accessor(self, index: int) -> np.ndarray:
        a = self.json["accessors"][index]
        assert "sparse" not in a, "sparse accessors are not used by these files"
        view = self.json["bufferViews"][a["bufferView"]]
        width = WIDTH[a["type"]]
        dtype = np.dtype("<" + COMPONENT[a["componentType"]])
        start = view.get("byteOffset", 0) + a.get("byteOffset", 0)
        stride = view.get("byteStride", width * dtype.itemsize)
        if stride == width * dtype.itemsize:
            flat = np.frombuffer(self.bin, dtype=dtype, count=width * a["count"], offset=start)
            return flat.reshape(a["count"], width)
        rows = [np.frombuffer(self.bin, dtype=dtype, count=width, offset=start + i * stride) for i in range(a["count"])]
        return np.stack(rows)

    def image_bytes(self, index: int) -> bytes:
        """The image as PNG bytes (any other format is re-encoded losslessly)"""
        image = self.json["images"][index]
        if "bufferView" in image:
            view = self.json["bufferViews"][image["bufferView"]]
            start = view.get("byteOffset", 0)
            raw = self.bin[start : start + view["byteLength"]]
        else:
            raw = (self.path.parent / image["uri"]).read_bytes()
        if raw[:8] == b"\x89PNG\r\n\x1a\n":
            return bytes(raw)
        return png(Image.open(io.BytesIO(raw)))

    def parents(self) -> dict[int, int]:
        out = {}
        for i, node in enumerate(self.json["nodes"]):
            for child in node.get("children", []):
                out[child] = i
        return out


# glTF writing -------------------------------------------------------------------------------------------------------


class GltfBuilder:
    def __init__(self):
        self.json: dict = {
            "asset": {"version": "2.0", "generator": "spiderman_bevy roblox_port/tools/build_roblox_pack.py"},
            "scene": 0,
            "scenes": [{"name": "Scene", "nodes": []}],
            "nodes": [],
            "meshes": [],
            "materials": [],
            "textures": [],
            "images": [],
            "samplers": [{"magFilter": 9729, "minFilter": 9987}],
            "accessors": [],
            "bufferViews": [],
            "buffers": [],
        }
        self.bin = bytearray()
        self.images_by_hash: dict[str, int] = {}

    def view(self, data: bytes, target: int | None = None) -> int:
        while len(self.bin) % 4:
            self.bin.append(0)
        view = {"buffer": 0, "byteOffset": len(self.bin), "byteLength": len(data)}
        if target:
            view["target"] = target
        self.bin += data
        self.json["bufferViews"].append(view)
        return len(self.json["bufferViews"]) - 1

    def accessor(self, array: np.ndarray, kind: str, target: int | None = None, bounds: bool = False) -> int:
        component = {np.dtype("<f4"): 5126, np.dtype("uint8"): 5121, np.dtype("<u2"): 5123, np.dtype("<u4"): 5125}
        array = np.ascontiguousarray(array)
        accessor = {
            "bufferView": self.view(array.tobytes(), target),
            "componentType": component[array.dtype],
            "count": int(array.shape[0]),
            "type": kind,
        }
        if bounds:
            accessor["min"] = [float(x) for x in array.min(axis=0)]
            accessor["max"] = [float(x) for x in array.max(axis=0)]
        self.json["accessors"].append(accessor)
        return len(self.json["accessors"]) - 1

    def texture(self, png: bytes, name: str) -> int:
        digest = hashlib.sha256(png).hexdigest()
        if digest not in self.images_by_hash:
            self.json["images"].append({"name": name, "mimeType": "image/png", "bufferView": self.view(png)})
            self.json["textures"].append({"sampler": 0, "source": len(self.json["images"]) - 1})
            self.images_by_hash[digest] = len(self.json["textures"]) - 1
        return self.images_by_hash[digest]

    def write(self, path: Path):
        doc = dict(self.json)
        for key in ("meshes", "materials", "textures", "images", "accessors", "bufferViews"):
            if not doc[key]:
                del doc[key]
        while len(self.bin) % 4:
            self.bin.append(0)
        doc["buffers"] = [{"byteLength": len(self.bin)}]
        text = json.dumps(doc, separators=(",", ":")).encode()
        text += b" " * (-len(text) % 4)
        total = 12 + 8 + len(text) + 8 + len(self.bin)
        with path.open("wb") as f:
            f.write(struct.pack("<4sII", b"glTF", 2, total))
            f.write(struct.pack("<I4s", len(text), b"JSON") + text)
            f.write(struct.pack("<I4s", len(self.bin), b"BIN\0") + self.bin)


# Materials ----------------------------------------------------------------------------------------------------------


def srgb_to_linear(c: np.ndarray) -> np.ndarray:
    return np.where(c <= 0.04045, c / 12.92, ((c + 0.055) / 1.055) ** 2.4)


def linear_to_srgb(c: np.ndarray) -> np.ndarray:
    c = np.clip(c, 0, 1)
    return np.where(c <= 0.0031308, c * 12.92, 1.055 * c ** (1 / 2.4) - 0.055)


def png(image: Image.Image) -> bytes:
    out = io.BytesIO()
    image.save(out, format="PNG", optimize=True)
    return out.getvalue()


def constant_png(rgba: list[int]) -> bytes:
    return png(Image.new("RGBA", (4, 4), tuple(int(v) for v in rgba)))


def bake_material(src: Gltf, material: dict, out: GltfBuilder, report: list) -> int:
    """The material as Roblox's importer can carry it: a colour map with the base colour factor multiplied in, the
    normal map as it is (Bevy ignores normalTexture.scale, so does this), and the metallic and roughness factors as a
    constant metallicRoughness map with its factors at 1. Alpha mode, cutoff and double-sidedness are kept."""
    pbr = material.get("pbrMetallicRoughness", {})
    factor = np.array(pbr.get("baseColorFactor", [1, 1, 1, 1]), dtype=np.float64)
    metallic = float(pbr.get("metallicFactor", 1.0))
    roughness = float(pbr.get("roughnessFactor", 1.0))
    name = material.get("name", "material")
    new = {"name": name, "pbrMetallicRoughness": {"metallicFactor": 1.0, "roughnessFactor": 1.0}}
    if "baseColorTexture" in pbr:
        texture = src.json["textures"][pbr["baseColorTexture"]["index"]]
        raw = src.image_bytes(texture["source"])
        if np.all(factor == 1):
            colour = raw
        else:
            # glTF multiplies the factor in linear space: bake it the same way, back to sRGB 8-bit
            image = np.asarray(Image.open(io.BytesIO(raw)).convert("RGBA"), dtype=np.float64) / 255
            image[..., :3] = linear_to_srgb(srgb_to_linear(image[..., :3]) * factor[:3])
            image[..., 3] = image[..., 3] * factor[3]
            colour = png(Image.fromarray(np.round(image * 255).astype(np.uint8), "RGBA"))
        new["pbrMetallicRoughness"]["baseColorTexture"] = {"index": out.texture(colour, name + "_color")}
    else:
        rgba = list(np.round(linear_to_srgb(factor[:3]) * 255)) + [round(factor[3] * 255)]
        new["pbrMetallicRoughness"]["baseColorTexture"] = {
            "index": out.texture(constant_png(rgba), f"color_{'_'.join(str(int(v)) for v in rgba)}")
        }
    # glTF's metallicRoughness map: G = roughness, B = metalness (linear)
    mr = [255, round(roughness * 255), round(metallic * 255), 255]
    new["pbrMetallicRoughness"]["metallicRoughnessTexture"] = {
        "index": out.texture(constant_png(mr), f"metal{mr[2]}_rough{mr[1]}")
    }
    if "normalTexture" in material:
        texture = src.json["textures"][material["normalTexture"]["index"]]
        new["normalTexture"] = {"index": out.texture(src.image_bytes(texture["source"]), name + "_normal")}
    for key in ("alphaMode", "alphaCutoff", "doubleSided"):
        if key in material:
            new[key] = material[key]
    out.json["materials"].append(new)
    report.append(
        {
            "material": name,
            "base_color_factor": factor.tolist(),
            "metallic": metallic,
            "roughness": roughness,
            "metallic_8bit": mr[2] / 255,
            "roughness_8bit": mr[1] / 255,
            "alpha_mode": material.get("alphaMode", "OPAQUE"),
            "double_sided": material.get("doubleSided", False),
            "has_color_texture": "baseColorTexture" in pbr,
            "has_normal_texture": "normalTexture" in material,
        }
    )
    return len(out.json["materials"]) - 1


# Meshes -------------------------------------------------------------------------------------------------------------


def split_triangles(triangles: np.ndarray, positions: np.ndarray, limit: int) -> list[np.ndarray]:
    """Triangle index lists of at most `limit` each. Connected pieces stay together where they fit, and the cut
    runs along the longest axis, so a split leaves few seams (the vertices on a seam are copied with their normals,
    UVs and weights, so nothing shows)."""
    count = len(triangles)
    if count <= limit:
        return [np.arange(count)]
    parent = np.arange(len(positions))

    def find(x):
        while parent[x] != x:
            parent[x] = parent[parent[x]]
            x = parent[x]
        return x

    for a, b, c in triangles:
        ra, rb, rc = find(a), find(b), find(c)
        parent[rb] = ra
        parent[find(rc)] = ra
    roots = np.array([find(t[0]) for t in triangles])
    centroids = positions[triangles].mean(axis=1)
    axis = int(np.argmax(positions.max(axis=0) - positions.min(axis=0)))
    piece_at = {}
    for r in np.unique(roots):
        piece_at[r] = centroids[roots == r, axis].mean()
    order = sorted(range(count), key=lambda t: (piece_at[roots[t]], roots[t], centroids[t, axis]))
    chunks = math.ceil(count / limit)
    size = math.ceil(count / chunks)
    return [np.array(order[i : i + size]) for i in range(0, count, size)]


def primitive_arrays(src: Gltf, primitive: dict) -> tuple[dict[str, np.ndarray], np.ndarray]:
    attributes = {name: src.accessor(index) for name, index in primitive["attributes"].items()}
    indices = src.accessor(primitive["indices"]).reshape(-1, 3).astype(np.int64)
    return attributes, indices


def write_primitive(out: GltfBuilder, attributes: dict, triangles: np.ndarray, material: int, scale: float) -> dict:
    used, remap = np.unique(triangles, return_inverse=True)
    local = remap.reshape(-1, 3)
    prim = {"attributes": {}, "material": material}
    for name, values in attributes.items():
        part = values[used]
        if name == "POSITION":
            part = (part.astype(np.float64) * scale).astype("<f4")
            prim["attributes"][name] = out.accessor(part, "VEC3", 34962, bounds=True)
        elif name in ("NORMAL",):
            prim["attributes"][name] = out.accessor(part.astype("<f4"), "VEC3", 34962)
        elif name.startswith("TEXCOORD"):
            prim["attributes"][name] = out.accessor(part.astype("<f4"), "VEC2", 34962)
        elif name.startswith("JOINTS"):
            prim["attributes"][name] = out.accessor(part.astype(values.dtype), "VEC4", 34962)
        elif name.startswith("WEIGHTS"):
            prim["attributes"][name] = out.accessor(part.astype("<f4"), "VEC4", 34962)
        else:
            raise ValueError(f"unexpected attribute {name}")
    index_type = "<u2" if len(used) < 65536 else "<u4"
    prim["indices"] = out.accessor(local.reshape(-1).astype(index_type), "SCALAR", 34963)
    return prim


# Transforms ---------------------------------------------------------------------------------------------------------


def quat_matrix(q) -> np.ndarray:
    x, y, z, w = q
    return np.array(
        [
            [1 - 2 * (y * y + z * z), 2 * (x * y - z * w), 2 * (x * z + y * w)],
            [2 * (x * y + z * w), 1 - 2 * (x * x + z * z), 2 * (y * z - x * w)],
            [2 * (x * z - y * w), 2 * (y * z + x * w), 1 - 2 * (x * x + y * y)],
        ]
    )


def trs(t, r, s) -> np.ndarray:
    m = np.eye(4)
    m[:3, :3] = quat_matrix(r) @ np.diag(s)
    m[:3, 3] = t
    return m


def quat_mul(a, b):
    ax, ay, az, aw = a
    bx, by, bz, bw = b
    return np.array(
        [
            aw * bx + ax * bw + ay * bz - az * by,
            aw * by - ax * bz + ay * bw + az * bx,
            aw * bz + ax * by - ay * bx + az * bw,
            aw * bw - ax * bx - ay * by - az * bz,
        ]
    )


def slerp(a, b, s):
    """glam's Quat::slerp, which Bevy uses for rotation keys and for blending (with exact acos)"""
    a = np.asarray(a, dtype=np.float64)
    b = np.asarray(b, dtype=np.float64)
    dot = float(np.dot(a, b))
    if dot < 0:
        b = -b
        dot = -dot
    if dot > 1 - 1.1920929e-07:
        r = a + (b - a) * s
        return r / np.linalg.norm(r)
    theta = math.acos(dot)
    return (a * math.sin(theta * (1 - s)) + b * math.sin(theta * s)) / math.sin(theta)


def node_trs(node: dict):
    assert "matrix" not in node, "these files use TRS nodes"
    return (
        np.array(node.get("translation", [0, 0, 0]), dtype=np.float64),
        np.array(node.get("rotation", [0, 0, 0, 1]), dtype=np.float64),
        np.array(node.get("scale", [1, 1, 1]), dtype=np.float64),
    )


# Character ----------------------------------------------------------------------------------------------------------


def build_character(manifest: dict) -> dict:
    src = Gltf(ASSETS / "character" / "spiderman.glb")
    j = src.json
    skin = j["skins"][0]
    joints = skin["joints"]
    parents = src.parents()
    out = GltfBuilder()
    k = STUDS_PER_METRE

    # every node keeps its index, so the skin's joint list stays as it is; translations go to studs
    for node in j["nodes"]:
        new = {key: list(value) if isinstance(value, list) else value for key, value in node.items() if key in ("name", "children", "translation", "rotation", "scale")}
        if "translation" in new:
            new["translation"] = [float(np.float32(v * k)) for v in new["translation"]]
        out.json["nodes"].append(new)
    out.json["scenes"][0]["nodes"] = list(j["scenes"][j.get("scene", 0)]["nodes"])
    armature = [i for i, n in enumerate(j["nodes"]) if n.get("name") == "SpiderMan"][0]

    materials = []
    material_index = {}
    for m, material in enumerate(j["materials"]):
        material_index[m] = bake_material(src, material, out, materials)

    parts = []
    for node_index, node in enumerate(j["nodes"]):
        if "mesh" not in node:
            continue
        assert not any(key in node for key in ("translation", "rotation", "scale", "matrix")), "mesh nodes sit at the origin"
        mesh = j["meshes"][node["mesh"]]
        assert len(mesh["primitives"]) == 1
        primitive = mesh["primitives"][0]
        attributes, triangles = primitive_arrays(src, primitive)
        weights = attributes["WEIGHTS_0"]
        assert np.allclose(weights.sum(axis=1), 1, atol=1e-3), "weights are normalised"
        chunks = split_triangles(triangles, attributes["POSITION"], TRIANGLE_LIMIT)
        for c, chunk in enumerate(chunks):
            name = node["name"] if len(chunks) == 1 else f"{node['name']}_{'abcdefgh'[c]}"
            prim = write_primitive(out, attributes, triangles[chunk], material_index[primitive["material"]], k)
            out.json["meshes"].append({"name": name, "primitives": [prim]})
            mesh_id = len(out.json["meshes"]) - 1
            if c == 0:
                target = out.json["nodes"][node_index]
                target["name"] = name
            else:
                out.json["nodes"].append({"name": name})
                target = out.json["nodes"][-1]
                out.json["nodes"][parents[node_index]]["children"].append(len(out.json["nodes"]) - 1)
            target["mesh"] = mesh_id
            target["skin"] = 0
            parts.append(
                {
                    "name": name,
                    "source_mesh": node["name"],
                    "material": j["materials"][primitive["material"]].get("name"),
                    "triangles": int(len(chunk)),
                }
            )

    ibm = src.accessor(skin["inverseBindMatrices"]).reshape(-1, 4, 4).transpose(0, 2, 1).astype(np.float64)
    scaled = ibm.copy()
    scaled[:, :3, 3] *= k
    out.json["skins"] = [
        {
            "name": skin.get("name", "SpiderMan"),
            "joints": joints,
            "inverseBindMatrices": out.accessor(scaled.transpose(0, 2, 1).reshape(-1, 16).astype("<f4"), "MAT4"),
        }
    ]
    out.write(OUT / "import" / "SpiderMan.glb")

    # the skeleton as the simulation and the clips see it (metres), and the bind check
    world = {}

    def world_of(i):
        if i not in world:
            local = trs(*node_trs(j["nodes"][i]))
            world[i] = (world_of(parents[i]) @ local) if i in parents else local
        return world[i]

    joint_of_node = {n: i for i, n in enumerate(joints)}
    skeleton = []
    bind_error = 0.0
    for i, n in enumerate(joints):
        node = j["nodes"][n]
        t, r, s = node_trs(node)
        bind_error = max(bind_error, float(np.abs(world_of(n) @ ibm[i] - np.eye(4)).max()))
        skeleton.append(
            {
                "name": node["name"],
                "parent": joint_of_node.get(parents.get(n), -1),
                "t": t.tolist(),
                "r": r.tolist(),
                "s": s.tolist(),
                "inverse_bind": ibm[i].reshape(-1).tolist(),  # row-major 4x4, metres
            }
        )
    names = [s["name"] for s in skeleton]
    assert len(set(names)) == len(names), "joint names are unique (Roblox finds bones by name)"
    rest_check = {}
    for name in ("head", "neck", "spine", "pelvis", "LF_wrist", "RT_wrist", "LF_foot", "RT_foot"):
        if name in names:
            p = world_of(joints[names.index(name)])[:3, 3]
            rest_check[name] = [round(float(v) * k, 4) for v in p]
    manifest["character"] = {
        "file": "import/SpiderMan.glb",
        "armature_root": j["nodes"][armature]["name"],
        "joints": len(joints),
        "mesh_parts": parts,
        "triangles": int(sum(p["triangles"] for p in parts)),
        "materials": materials,
        "bind_pose_max_error": bind_error,
        "rest_joint_positions_studs": rest_check,
        "bounds_studs": {
            "min": [round(float(v) * k, 4) for v in np.min([src.accessor(m["primitives"][0]["attributes"]["POSITION"]).min(axis=0) for m in j["meshes"]], axis=0)],
            "max": [round(float(v) * k, 4) for v in np.max([src.accessor(m["primitives"][0]["attributes"]["POSITION"]).max(axis=0) for m in j["meshes"]], axis=0)],
        },
    }
    return {"skeleton": skeleton, "gltf": src}


# World kits ---------------------------------------------------------------------------------------------------------


def build_kit(name: str, assets: list[str], manifest: dict):
    out = GltfBuilder()
    k = STUDS_PER_METRE
    entries = []
    for asset in assets:
        src = Gltf(ASSETS / asset)
        j = src.json
        stem = Path(asset).stem
        root = {"name": stem, "children": []}
        out.json["nodes"].append(root)
        root_index = len(out.json["nodes"]) - 1
        out.json["scenes"][0]["nodes"].append(root_index)
        materials = []
        material_index = {m: bake_material(src, material, out, materials) for m, material in enumerate(j["materials"])}
        parts = []
        lo = np.full(3, np.inf)
        hi = np.full(3, -np.inf)
        for node in j["nodes"]:
            if "mesh" not in node:
                continue
            assert not any(key in node for key in ("translation", "rotation", "scale", "matrix")), "kit meshes sit at the origin"
            for p, primitive in enumerate(j["meshes"][node["mesh"]]["primitives"]):
                attributes, triangles = primitive_arrays(src, primitive)
                lo = np.minimum(lo, attributes["POSITION"].min(axis=0))
                hi = np.maximum(hi, attributes["POSITION"].max(axis=0))
                chunks = split_triangles(triangles, attributes["POSITION"], TRIANGLE_LIMIT)
                for c, chunk in enumerate(chunks):
                    part = f"{stem}_p{p:02d}" + ("" if len(chunks) == 1 else "_" + "abcdefgh"[c])
                    prim = write_primitive(out, attributes, triangles[chunk], material_index[primitive["material"]], k)
                    out.json["meshes"].append({"name": part, "primitives": [prim]})
                    out.json["nodes"].append({"name": part, "mesh": len(out.json["meshes"]) - 1})
                    root["children"].append(len(out.json["nodes"]) - 1)
                    parts.append({"name": part, "primitive": p, "triangles": int(len(chunk))})
        entries.append(
            {
                "model": stem,
                "source": asset,
                "parts": parts,
                "materials": materials,
                "bounds_studs": {"min": (lo * k).round(4).tolist(), "max": (hi * k).round(4).tolist()},
            }
        )
    out.write(OUT / "import" / f"{name}.glb")
    manifest["kits"][name] = {"file": f"import/{name}.glb", "models": entries}


# Data pack ----------------------------------------------------------------------------------------------------------


def encode_clip(src: Gltf, animation: dict, joints: list[int]) -> tuple[bytes, dict]:
    j = src.json
    slot = {n: i for i, n in enumerate(joints)}
    channels = {}
    for ch in animation["channels"]:
        node = ch["target"]["node"]
        path = {"translation": 0, "rotation": 1, "scale": 2}[ch["target"]["path"]]
        assert node in slot, "every animated node is a skin joint"
        channels[(slot[node], path)] = animation["samplers"][ch["sampler"]]
    time_sets: dict[int, int] = {}
    times = []
    headers = []
    words = []
    duration = 0.0
    stats = {"constant": 0, "keyed": 0, "missing": 0}
    for joint in range(len(joints)):
        for path in range(3):
            sampler = channels.get((joint, path))
            if sampler is None:
                headers.append(struct.pack("<BHI", 0, 0, 0))
                stats["missing"] += 1
                continue
            interp = {"LINEAR": 0, "STEP": 1, "CUBICSPLINE": 2}[sampler.get("interpolation", "LINEAR")]
            assert interp != 2, "no cubic spline keys in these clips"
            if sampler["input"] not in time_sets:
                time_sets[sampler["input"]] = len(times)
                t = src.accessor(sampler["input"]).reshape(-1).astype("<f4")
                times.append(t)
                duration = max(duration, float(t[-1]))
            values = src.accessor(sampler["output"]).astype("<f4")
            assert values.shape[1] == (4 if path == 1 else 3)
            assert len(values) == len(times[time_sets[sampler["input"]]])
            bits = values.view("<u4")
            constant = bool(np.all(bits == bits[0]))
            flags = interp | 4 | (8 if constant else 0)
            stored = 1 if constant else len(values)
            headers.append(struct.pack("<BHI", flags, time_sets[sampler["input"]], stored))
            if constant:
                words.append(bits[0].copy())
                stats["constant"] += 1
            else:
                for c in range(values.shape[1]):
                    run = bits[:, c].astype(np.int64)
                    delta = np.empty_like(run)
                    delta[0] = run[0]
                    delta[1:] = (run[1:] - run[:-1]) & 0xFFFFFFFF
                    words.append(delta.astype("<u4"))
                stats["keyed"] += 1
    stream = np.concatenate(words).astype("<u4")
    planes = stream.view(np.uint8).reshape(-1, 4).T.copy().tobytes()
    name = animation["name"].encode()
    head = b"SMC1" + struct.pack("<H", len(name)) + name + struct.pack("<fHH", duration, len(joints), len(times))
    for t in times:
        head += struct.pack("<I", len(t)) + t.tobytes()
    head += struct.pack("<I", len(headers)) + b"".join(headers) + struct.pack("<I", len(stream))
    stats["duration"] = duration
    stats["keys"] = int(max(len(t) for t in times))
    return head + planes, stats


def encode_mesh(positions: np.ndarray, indices: np.ndarray) -> bytes:
    return (
        b"SMM1"
        + struct.pack("<I", len(positions))
        + positions.astype("<f4").tobytes()
        + struct.pack("<I", indices.size)
        + indices.reshape(-1).astype("<u4").tobytes()
    )


class Pack:
    """A tree of Folders and ModuleScripts written as an .rbxmx model file"""

    def __init__(self, compress: bool):
        self.compress = compress
        self.root = {"class": "Folder", "name": "SpiderManData", "children": []}
        self.module_count = 0
        self.payload_bytes = 0

    def folder(self, parent: dict, name: str) -> dict:
        node = {"class": "Folder", "name": name, "children": []}
        parent["children"].append(node)
        return node

    def module(self, parent: dict, name: str, source: str):
        assert len(source) <= SOURCE_LIMIT, f"{name} is {len(source)} characters"
        parent["children"].append({"class": "ModuleScript", "name": name, "source": source, "children": []})
        self.module_count += 1

    def text(self, parent: dict, name: str, text: str):
        """A ModuleScript that returns `text` (a long bracket string, so JSON needs no escaping)"""
        level = 0
        while ("]" + "=" * level + "]") in text:
            level += 1
        eq = "=" * level
        self.module(parent, name, f"return [{eq}[\n{text}]{eq}]\n")

    def json(self, parent: dict, name: str, value):
        text = json.dumps(value, separators=(",", ":"))
        self.text(parent, name, text)

    def payload(self, parent: dict, name: str, data: bytes):
        """`data`, Zstd-compressed and base64-encoded, as numbered ModuleScripts under a folder `name`"""
        if self.compress:
            data = zstandard.ZstdCompressor(level=19, write_content_size=True).compress(data)
        self.payload_bytes += len(data)
        text = base64.b64encode(data).decode()
        folder = self.folder(parent, name)
        for i in range(0, len(text), PART_CHARS):
            self.module(folder, f"{i // PART_CHARS + 1:03d}", f'return "{text[i : i + PART_CHARS]}"\n')
        return folder

    def write(self, path: Path):
        counter = [0]

        def item(node, depth):
            counter[0] += 1
            pad = "\t" * depth
            lines = [f'{pad}<Item class="{node["class"]}" referent="RBX{counter[0]}">', f"{pad}\t<Properties>"]
            lines.append(f'{pad}\t\t<string name="Name">{escape(node["name"])}</string>')
            if node["class"] == "ModuleScript":
                lines.append(f'{pad}\t\t<ProtectedString name="Source">{escape(node["source"])}</ProtectedString>')
            lines.append(f"{pad}\t</Properties>")
            for child in node["children"]:
                lines.extend(item(child, depth + 1))
            lines.append(f"{pad}</Item>")
            return lines

        body = item(self.root, 1)
        text = "\n".join(
            [
                '<roblox xmlns:xmime="http://www.w3.org/2005/05/xmlmime" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" '
                'xsi:noNamespaceSchemaLocation="http://www.roblox.com/roblox.xsd" version="4">',
                *body,
                "</roblox>",
                "",
            ]
        )
        path.write_text(text, encoding="utf-8", newline="\n")


# Reference poses ----------------------------------------------------------------------------------------------------


def sample_channel(times: np.ndarray, values: np.ndarray, interp: str, t: float, rotation: bool):
    """Bevy's sampling of a glTF keyframe curve (UnevenCore): clamped at the ends, exact on a key"""
    values = values.astype(np.float64)
    if len(times) == 1 or t <= times[0]:
        return values[0]
    if t >= times[-1]:
        return values[-1]
    i = int(np.searchsorted(times, t, side="right")) - 1
    if times[i] == t:
        return values[i]
    s = (t - float(times[i])) / (float(times[i + 1]) - float(times[i]))
    if interp == "STEP":
        return values[i + 1] if s >= 1 else values[i]
    if rotation:
        return slerp(values[i], values[i + 1], s)
    return values[i] * (1 - s) + values[i + 1] * s


def clip_locals(src: Gltf, animation: dict, joints: list[int], t: float) -> list:
    slot = {n: i for i, n in enumerate(joints)}
    local = [list(node_trs(src.json["nodes"][n])) for n in joints]
    for ch in animation["channels"]:
        sampler = animation["samplers"][ch["sampler"]]
        path = {"translation": 0, "rotation": 1, "scale": 2}[ch["target"]["path"]]
        local[slot[ch["target"]["node"]]][path] = sample_channel(
            src.accessor(sampler["input"]).reshape(-1),
            src.accessor(sampler["output"]),
            sampler.get("interpolation", "LINEAR"),
            t,
            path == 1,
        )
    return local


def blend_locals(layers: list) -> list:
    """Bevy's blend node: layers in ascending node order (the clips sorted by name), each folded in with
    interpolate(acc, value, weight / weight so far); a single layer is used as it is whatever its weight"""
    layers = sorted(layers, key=lambda layer: layer[0])
    acc = [list(p) for p in layers[0][1]]
    total = layers[0][2]
    for _, local, weight in layers[1:]:
        total += weight
        s = weight / total
        for i, (t, r, sc) in enumerate(local):
            acc[i][0] = acc[i][0] * (1 - s) + t * s
            acc[i][1] = slerp(acc[i][1], r, s)
            acc[i][2] = acc[i][2] * (1 - s) + sc * s
    return acc


def pose_report(skeleton: list, local: list) -> list:
    """Per joint: its position (metres, through every translation, rotation and scale above it, as Bevy draws it)
    and its rotation with the scales left out (the product of the local rotations, which Roblox bones can show)"""
    world = [None] * len(skeleton)
    rot = [None] * len(skeleton)
    out = []
    for i, joint in enumerate(skeleton):
        t, r, s = local[i]
        m = trs(t, r, s)
        p = joint["parent"]
        world[i] = m if p < 0 else world[p] @ m
        rot[i] = np.array(r, dtype=np.float64) if p < 0 else quat_mul(rot[p], r)
        rot[i] = rot[i] / np.linalg.norm(rot[i])
        if rot[i][3] < 0:
            rot[i] = -rot[i]
        out.append([round(float(v), 7) for v in [*world[i][:3, 3], *rot[i]]])
    return out


# Main ---------------------------------------------------------------------------------------------------------------


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--no-compress", action="store_true", help="store payloads without Zstd (about twice as big)")
    parser.add_argument("--luau", type=Path, help="a Luau CLI to run the decoder test with")
    args = parser.parse_args()
    (OUT / "import").mkdir(parents=True, exist_ok=True)
    manifest: dict = {
        "studs_per_metre": STUDS_PER_METRE,
        "triangle_limit": TRIANGLE_LIMIT,
        "kits": {},
    }

    print("character ...")
    character = build_character(manifest)
    skeleton = character["skeleton"]
    src: Gltf = character["gltf"]

    layout = json.loads((ASSETS / "world" / "layout.json").read_text())
    towers = sorted({b["asset"] for b in layout["buildings"]})
    props = sorted({c["asset"] for c in layout["cars"]} | {o["asset"] for o in layout["objects"]})
    print("towers kit ...")
    build_kit("CityTowers", towers, manifest)
    print("props kit ...")
    build_kit("CityProps", props, manifest)

    print("data pack ...")
    pack = Pack(compress=not args.no_compress)
    root = pack.root
    pack.json(root, "PackInfo", {"compression": "none" if args.no_compress else "zstd", "format": 1, "studs_per_metre": STUDS_PER_METRE})
    pack.module(root, "Decoder", (OUT / "luau" / "Decoder.luau").read_text())
    pack.json(root, "Skeleton", {"armature_root": manifest["character"]["armature_root"], "joints": skeleton})

    # every clip, bit for bit
    joints = src.json["skins"][0]["joints"]
    clips_folder = pack.folder(root, "Clips")
    clip_report = []
    encoded = {}
    for animation in src.json["animations"]:
        data, stats = encode_clip(src, animation, joints)
        encoded[animation["name"]] = data
        pack.payload(clips_folder, animation["name"], data)
        clip_report.append({"name": animation["name"], **stats})
    manifest["clips"] = clip_report
    conversion = json.loads((ASSETS / "character" / "conversion.json").read_text())
    durations = {c["name"]: c["duration"] for c in conversion["clips"]}
    manifest["clip_duration_max_difference_from_conversion_json"] = max(
        abs(durations[c["name"]] - c["duration"]) for c in clip_report if c["name"] in durations
    )

    # the collision triangles of everything that collides by its meshes (cars, objects, buildings without a box)
    collision = pack.folder(root, "Collision")
    models = pack.folder(collision, "Models")
    mesh_assets = sorted(
        {c["asset"] for c in layout["cars"]}
        | {o["asset"] for o in layout["objects"]}
        | {b["asset"] for b in layout["buildings"] if b.get("center") is None or b.get("half") is None}
    )
    index = {"units": "metres", "assets": {}, "models": {}}
    by_hash: dict[str, str] = {}
    first_mesh = None
    for asset in mesh_assets:
        g = Gltf(ASSETS / asset)
        primitives = []
        for node in g.json["nodes"]:
            if "mesh" not in node:
                continue
            assert not any(key in node for key in ("translation", "rotation", "scale", "matrix"))
            for p, primitive in enumerate(g.json["meshes"][node["mesh"]]["primitives"]):
                positions = g.accessor(primitive["attributes"]["POSITION"])
                indices = g.accessor(primitive["indices"]).reshape(-1)
                data = encode_mesh(positions, indices)
                digest = hashlib.sha256(data).hexdigest()
                if digest not in by_hash:
                    model_id = f"m{len(by_hash):03d}"
                    by_hash[digest] = model_id
                    pack.payload(models, model_id, data)
                    index["models"][model_id] = {"vertices": int(len(positions)), "triangles": int(len(indices) // 3)}
                    if first_mesh is None:
                        first_mesh = (model_id, positions, indices)
                primitives.append({"primitive": p, "model": by_hash[digest], "kit_part": f"{Path(asset).stem}_p{p:02d}"})
        index["assets"][asset] = primitives
    pack.json(collision, "Index", index)
    manifest["collision"] = {
        "assets": len(index["assets"]),
        "distinct_models": len(index["models"]),
        "triangles_distinct": int(sum(m["triangles"] for m in index["models"].values())),
    }

    # the data the game reads as it starts
    pack.text(root, "Layout", (ASSETS / "world" / "layout.json").read_text())
    pack.text(root, "Conversion", (ASSETS / "character" / "conversion.json").read_text())
    tuning = pack.folder(root, "Tuning")
    for path in sorted((ASSETS / "tuning").rglob("*.json")):
        pack.text(tuning, path.relative_to(ASSETS / "tuning").as_posix().replace("/", "__").removesuffix(".json"), path.read_text())
    # the original game's own runs: the scenario (inputs), the game's path, and the test's tolerance
    fixtures = pack.folder(root, "OracleFixtures")
    tests = (REPO / "crates" / "sm_traversal" / "tests" / "oracle_paths.rs").read_text()
    tolerances = {}
    for line in tests.splitlines():
        if line.startswith("scenario!("):
            name, tolerance = line.removeprefix("scenario!(").removesuffix(");").split(",")
            tolerances[name.strip()] = float(tolerance)
    for path in sorted((REPO / "crates" / "sm_traversal" / "tests" / "fixtures").glob("*.json")):
        folder = pack.folder(fixtures, path.stem)
        pack.text(folder, "Scenario", (REPO / "tools" / "native_oracle" / "scenarios" / f"{path.stem}.txt").read_text())
        pack.text(folder, "Game", path.read_text())
        pack.json(folder, "Check", {"position_tolerance_m": tolerances[path.stem], "facing_tolerance_deg": 0.5, "same_mode_every_frame": True})
    assert set(tolerances) == {p.stem for p in (REPO / "crates" / "sm_traversal" / "tests" / "fixtures").glob("*.json")}

    # reference poses for checking the Studio sampler, blender and skinning against
    reference = pack.folder(root, "ReferencePoses")
    animations = {a["name"]: a for a in src.json["animations"]}
    samples = [
        ("stand_idle_spiderman", 1.0),
        ("web_swing_fwd_rh_spiderman", 2.0123),
        ("web_swing_fwd_rh_spiderman_mirrored", 2.0123),
        ("web_zip_attach_fwd_spiderman", 0.5),
        ("fall_cycle_spiderman", 1.2345),
        ("web_swing_jump_high_spiderman", 0.9),
    ]
    for n, (clip, t) in enumerate(samples, start=1):
        local = clip_locals(src, animations[clip], joints, t)
        pack.json(reference, f"{n:02d}_{clip}", {"layers": [[clip, t, 1.0]], "joints": pose_report(skeleton, local)})
    blend = [("web_swing_fwd_rh_spiderman", 1.5, 0.35), ("web_swing_release_high_spiderman", 0.4, 0.45), ("fall_cycle_spiderman", 0.7, 0.2)]
    local = blend_locals([(c, clip_locals(src, animations[c], joints, t), w) for c, t, w in blend])
    pack.json(reference, f"{len(samples) + 1:02d}_blend", {"layers": [list(b) for b in blend], "joints": pose_report(skeleton, local)})
    pack.text(
        reference,
        "README",
        json.dumps(
            {
                "joints": "one row per skin joint (Skeleton order): world x, y, z in metres with the armature root at the origin, then the world rotation x, y, z, w with the scales left out",
                "position": "through every translation, rotation and scale above the joint (Bevy's transform propagation)",
                "rotation": "the product of the local rotations from the root down (what a Roblox bone can show)",
                "sampling": "Bevy 0.19.1: clamped at the ends, exact on a key, LINEAR = lerp / glam slerp, STEP holds the earlier key",
                "blend": "layers in ascending clip-name order, folded with interpolate(acc, value, weight / weight so far)",
            }
        ),
    )

    pack.write(OUT / "SpiderManData.rbxmx")
    manifest["pack"] = {
        "file": "SpiderManData.rbxmx",
        "module_scripts": pack.module_count,
        "payload_bytes": pack.payload_bytes,
        "compression": "none" if args.no_compress else "zstd",
    }
    for name in ("SpiderMan.glb", "CityTowers.glb", "CityProps.glb"):
        manifest.setdefault("file_sizes_mb", {})[f"import/{name}"] = round((OUT / "import" / name).stat().st_size / 1e6, 1)
    manifest["file_sizes_mb"]["SpiderManData.rbxmx"] = round((OUT / "SpiderManData.rbxmx").stat().st_size / 1e6, 1)
    (OUT / "manifest.json").write_text(json.dumps(manifest, indent=1) + "\n")

    verify_python(src, encoded, joints)
    if args.luau:
        verify_luau(args.luau, src, encoded, joints, first_mesh)
    print(json.dumps({k: manifest[k] for k in ("pack", "file_sizes_mb", "collision")}, indent=1))


# Checks -------------------------------------------------------------------------------------------------------------


def decode_clip_python(data: bytes) -> dict:
    """An independent reading of the clip layout (the Luau decoder's twin) for the round-trip check"""
    assert data[:4] == b"SMC1"
    o = 4
    (n,) = struct.unpack_from("<H", data, o)
    o += 2
    name = data[o : o + n].decode()
    o += n
    duration, joints, sets = struct.unpack_from("<fHH", data, o)
    o += 8
    times = []
    for _ in range(sets):
        (count,) = struct.unpack_from("<I", data, o)
        o += 4
        times.append(np.frombuffer(data, "<f4", count, o))
        o += 4 * count
    (channels,) = struct.unpack_from("<I", data, o)
    o += 4
    headers = [struct.unpack_from("<BHI", data, o + 7 * i) for i in range(channels)]
    o += 7 * channels
    (words,) = struct.unpack_from("<I", data, o)
    o += 4
    planes = np.frombuffer(data, np.uint8, 4 * words, o).reshape(4, words)
    stream = planes.T.copy().view("<u4").reshape(-1).astype(np.int64)
    at = 0
    out = {}
    for c, (flags, set_index, keys) in enumerate(headers):
        if not flags & 4:
            continue
        width = 4 if c % 3 == 1 else 3
        if flags & 8:
            values = stream[at : at + width].reshape(1, width)
        else:
            values = np.stack([np.cumsum(stream[at + i * keys : at + (i + 1) * keys]) & 0xFFFFFFFF for i in range(width)], axis=1)
        at += width * keys
        out[(c // 3, c % 3)] = (flags & 3, times[set_index], values.astype("<u4").view("<f4"))
    assert at == words
    return {"name": name, "duration": duration, "channels": out}


def verify_python(src: Gltf, encoded: dict, joints: list[int]):
    slot = {n: i for i, n in enumerate(joints)}
    checked = 0
    for animation in src.json["animations"]:
        decoded = decode_clip_python(encoded[animation["name"]])
        for ch in animation["channels"]:
            sampler = animation["samplers"][ch["sampler"]]
            path = {"translation": 0, "rotation": 1, "scale": 2}[ch["target"]["path"]]
            interp, times, values = decoded["channels"][(slot[ch["target"]["node"]], path)]
            original = src.accessor(sampler["output"]).astype("<f4")
            assert np.array_equal(times.view("<u4"), src.accessor(sampler["input"]).reshape(-1).astype("<f4").view("<u4"))
            if len(values) == 1:
                assert np.all(original.view("<u4") == values.view("<u4")[0])
            else:
                assert np.array_equal(original.view("<u4"), values.view("<u4"))
            assert interp == {"LINEAR": 0, "STEP": 1}[sampler.get("interpolation", "LINEAR")]
            checked += 1
    print(f"python round trip: {checked} channels in {len(encoded)} clips identical to the glTF, bit for bit")


def luau_string(data: bytes) -> str:
    return '"' + "".join(f"\\x{b:02x}" for b in data) + '"'


def verify_luau(luau: Path, src: Gltf, encoded: dict, joints: list[int], first_mesh):
    """Runs Decoder.parseClip / parseMesh in the Luau CLI and checks a checksum of every decoded word"""
    names = ["web_swing_2rh_000_bend_l_spiderman", "stand_sprint_fwd_spiderman", "web_zip_attach_short_fwd_spiderman"]
    with tempfile.TemporaryDirectory() as tmp:
        tmp = Path(tmp)
        (tmp / "Decoder.luau").write_text((OUT / "luau" / "Decoder.luau").read_text())
        lines = ['local Decoder = require("./Decoder")', "local function sum(b, n) local s = 0 for i = 0, n - 1 do s = (s + buffer.readu32(b, i * 4) * (i % 7 + 1)) % 4294967291 end return s end"]
        expected = []
        for name in names:
            data = encoded[name]
            lines.append(f"do local c = Decoder.parseClip(buffer.fromstring({luau_string(data)}))")
            lines.append("  local s, n, k = 0, 0, 0")
            lines.append("  for j = 1, c.joints do for _, p in {'T','R','S'} do local ch = c.channels[j][p] if ch then")
            lines.append("    for i = 0, ch.keys * ch.width - 1 do s = (s + buffer.readu32(c.values, ch.offset + i * 4) * (i % 7 + 1)) % 4294967291 end n += 1 k += ch.keys end end end")
            lines.append("  print(c.name, n, k, s, string.format('%.6f', c.duration)) end")
            decoded = decode_clip_python(data)
            s = n = k = 0
            for joint in range(len(joints)):
                for path in range(3):
                    if (joint, path) not in decoded["channels"]:
                        continue
                    _, _, values = decoded["channels"][(joint, path)]
                    words = values.view("<u4").reshape(-1).astype(np.int64)
                    for i, w in enumerate(words):
                        s = (s + int(w) * (i % 7 + 1)) % 4294967291
                    n += 1
                    k += len(values)
            expected.append(f"{name}\t{n}\t{k}\t{s}\t{decoded['duration']:.6f}")
        model_id, positions, indices = first_mesh
        data = encode_mesh(positions, indices)
        lines.append(f"do local m = Decoder.parseMesh(buffer.fromstring({luau_string(data)}))")
        lines.append("  print('mesh', m.vertexCount, m.indexCount, sum(m.vertices, m.vertexCount * 3), sum(m.indices, m.indexCount)) end")
        vs = sum(int(w) * (i % 7 + 1) for i, w in enumerate(positions.astype("<f4").view("<u4").reshape(-1).astype(np.int64))) % 4294967291
        ins = sum(int(w) * (i % 7 + 1) for i, w in enumerate(indices.reshape(-1).astype(np.int64))) % 4294967291
        expected.append(f"mesh\t{len(positions)}\t{indices.size}\t{vs}\t{ins}")
        (tmp / "test.luau").write_text("\n".join(lines) + "\n")
        result = subprocess.run([str(luau), "test.luau"], cwd=tmp, capture_output=True, text=True, timeout=600)
        got = result.stdout.strip().splitlines()
        if result.returncode != 0 or got != expected:
            print(result.stdout, result.stderr, "expected:", *expected, sep="\n")
            sys.exit("Luau decoder check failed")
        print(f"luau decoder: {len(names)} clips and collision model {model_id} decode to the same words as the glTF")


if __name__ == "__main__":
    main()

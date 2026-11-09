"""Convertit le zip Sketchfab (scene.gltf + scene.bin) en app/src/main/assets/car.bin.

Format car.bin : int32 nCarrosserie, int32 nAutres, puis les sommets
(x y z nx ny nz r g b, float32 little-endian), carrosserie d'abord.
"""
import glob, json, os, struct, sys, zipfile
import numpy as np

TARGET_TRIS = 70000          # triangles visés pour toute la voiture
LENGTH = 4.07                # longueur finale (même échelle que la voiture simple)
BODY = ('Steel_Gray', 'Color_M02')   # matériaux "peinture" (couleur changeable)
DROP = ('Interior',)         # pièces invisibles (vitres opaques) : supprimées

TABLE = [
    ('Tires', (.07, .07, .08)), ('Rims', (.75, .77, .80)),
    ('WindowsTrims', (.05, .05, .07)), ('Windows', (.10, .14, .22)),
    ('Chrome', (.82, .84, .88)), ('Kia_Logo', (.82, .84, .88)), ('Badges', (.70, .70, .72)),
    ('BrakeLights', (.85, .08, .08)), ('DarkRed', (.55, .05, .07)), ('Red', (.85, .08, .08)),
    ('HeadLights', (.97, .97, .88)), ('DRL', (.97, .97, .90)), ('Reflectors', (.80, .80, .80)),
    ('Signal', (.95, .55, .10)), ('Black', (.05, .05, .07)), ('Grille', (.05, .05, .07)),
    ('UnderCarrier', (.08, .08, .10)), ('Mirrors', (.05, .05, .07)), ('Default_Material', (.10, .10, .12)),
    ('BrakeRotors', (.50, .50, .52)), ('Calipers', (.60, .10, .10)), ('License', (.90, .90, .90)),
]


def color_of(name):
    for k, v in TABLE:
        if k in name:
            return v
    return (.35, .35, .38)


zp = next(p for p in glob.glob('*.zip') if 'scene.gltf' in zipfile.ZipFile(p).namelist())
z = zipfile.ZipFile(zp)
j = json.loads(z.read('scene.gltf'))
buf = z.read(j['buffers'][0]['uri'])
print('zip:', zp, '| bin', len(buf) // 1024, 'Ko')

DT = {5120: 'i1', 5121: 'u1', 5122: 'i2', 5123: 'u2', 5125: 'u4', 5126: 'f4'}
NC = {'SCALAR': 1, 'VEC2': 2, 'VEC3': 3, 'VEC4': 4}


def acc(i):
    a = j['accessors'][i]
    bv = j['bufferViews'][a['bufferView']]
    dt = np.dtype(DT[a['componentType']])
    n = NC[a['type']]
    off = bv.get('byteOffset', 0) + a.get('byteOffset', 0)
    stride = bv.get('byteStride') or dt.itemsize * n
    out = np.empty((a['count'], n), dt)
    for k in range(n):
        out[:, k] = np.ndarray(a['count'], dt, buf, off + k * dt.itemsize, (stride,))
    return out


def local(nd):
    if 'matrix' in nd:
        return np.array(nd['matrix'], float).reshape(4, 4).T
    T, R, S = np.eye(4), np.eye(4), np.eye(4)
    T[:3, 3] = nd.get('translation', [0, 0, 0])
    S[0, 0], S[1, 1], S[2, 2] = nd.get('scale', [1, 1, 1])
    x, y, w_z, w = nd.get('rotation', [0, 0, 0, 1])
    R[:3, :3] = [
        [1 - 2 * (y * y + w_z * w_z), 2 * (x * y - w_z * w), 2 * (x * w_z + y * w)],
        [2 * (x * y + w_z * w), 1 - 2 * (x * x + w_z * w_z), 2 * (y * w_z - x * w)],
        [2 * (x * w_z - y * w), 2 * (y * w_z + x * w), 1 - 2 * (x * x + y * y)],
    ]
    return T @ R @ S


parts = []  # (nom matériau, points monde, triangles)


def walk(i, M):
    nd = j['nodes'][i]
    M = M @ local(nd)
    if 'mesh' in nd:
        for p in j['meshes'][nd['mesh']]['primitives']:
            if p.get('mode', 4) != 4:
                continue
            mat = j['materials'][p['material']]['name'] if 'material' in p else 'none'
            pos = acc(p['attributes']['POSITION']).astype(np.float64)
            idx = acc(p['indices']).reshape(-1).astype(np.int64) if 'indices' in p else np.arange(len(pos))
            parts.append((mat, pos @ M[:3, :3].T + M[:3, 3], idx.reshape(-1, 3)))
    for c in nd.get('children', []):
        walk(c, M)


for r in j['scenes'][j.get('scene', 0)]['nodes']:
    walk(r, np.eye(4))
parts = [p for p in parts if not any(d in p[0] for d in DROP)]

# --- orientation : Y vers le haut (glTF), avant de la voiture vers +x, centrée, longueur 4,07
allp = np.vstack([p for _, p, _ in parts])
mn, mx = allp.min(0), allp.max(0)
ext = mx - mn
ax = 0 if ext[0] > ext[2] else 2
mid = (mn + mx) / 2


def centroid(key):
    pts = [p for m, p, _ in parts if key in m]
    return np.vstack(pts).mean(0) if pts else None


h, t = centroid('HeadLights'), centroid('BrakeLightsBase')
sgn = 1 if (h is None or t is None or h[ax] >= t[ax]) else -1
s = LENGTH / ext[ax]
print('étendue brute', np.round(ext, 3), '| axe longueur', 'xz'[ax // 2], '| avant', sgn, '| échelle', s)


def place(p):
    q = p.copy()
    q[:, 0] -= mid[0]
    q[:, 2] -= mid[2]
    q[:, 1] -= mn[1]
    if ax == 0:
        x, z = sgn * q[:, 0], sgn * q[:, 2]
    else:
        x, z = sgn * q[:, 2], -sgn * q[:, 0]
    return np.stack([x, q[:, 1], z], 1) * s


# --- allègement
try:
    import fast_simplification as fs
except Exception:
    fs = None
    print('fast_simplification absent : décimation par clusters')


def weld(pts, f):
    key = np.round(pts / 1e-4).astype(np.int64)
    _, first, inv = np.unique(key, axis=0, return_index=True, return_inverse=True)
    f = inv.ravel()[f]
    ok = (f[:, 0] != f[:, 1]) & (f[:, 1] != f[:, 2]) & (f[:, 0] != f[:, 2])
    return pts[first], f[ok]


def cluster(pts, f, tgt):
    lo, hi = 1e-4, 0.5
    best = (pts, f)
    for _ in range(12):
        c = (lo * hi) ** 0.5
        key = np.floor(pts / c).astype(np.int64)
        _, first, inv = np.unique(key, axis=0, return_index=True, return_inverse=True)
        g = inv.ravel()[f]
        ok = (g[:, 0] != g[:, 1]) & (g[:, 1] != g[:, 2]) & (g[:, 0] != g[:, 2])
        if ok.sum() > tgt:
            lo = c
        else:
            hi = c
            best = (pts[first], g[ok])
    return best


placed = [(m, place(p), f) for m, p, f in parts]
total = sum(len(f) for _, _, f in placed)
ratio = min(1.0, TARGET_TRIS / total)
body_v, other_v = [], []
print('triangles avant :', total, '| ratio', round(ratio, 3))

for m, p, f in placed:
    p, f = weld(p, f)
    before = len(f)
    tgt = max(int(before * ratio), min(before, 120))
    if tgt < before * 0.95:
        try:
            if fs is not None:
                p, f = fs.simplify(p.astype(np.float32), f.astype(np.int32), target_reduction=1 - tgt / before)
                p, f = p.astype(np.float64), f.astype(np.int64)
            else:
                p, f = cluster(p, f, tgt)
        except Exception as e:
            print('  simplification ignorée pour', m, e)
    if len(f) == 0:
        continue
    p0, p1, p2 = p[f[:, 0]], p[f[:, 1]], p[f[:, 2]]
    fn = np.cross(p1 - p0, p2 - p0)
    if np.sum(np.einsum('ij,ij->i', fn, (p0 + p1 + p2) / 3 - p.mean(0))) < 0:   # normales vers l'extérieur
        f = f[:, ::-1]
        fn = -fn
    vn = np.zeros_like(p)
    for k in range(3):
        np.add.at(vn, f[:, k], fn)
    vn /= np.linalg.norm(vn, axis=1, keepdims=True) + 1e-12
    idx = f.reshape(-1)
    is_body = any(b in m for b in BODY)
    col = (0.5, 0.5, 0.5) if is_body else color_of(m)
    v = np.hstack([p[idx], vn[idx], np.tile(col, (len(idx), 1))]).astype('<f4')
    (body_v if is_body else other_v).append(v)
    print(f'  {m[-26:]:<26} {before:>6} -> {len(f):>6} {"[PEINTURE]" if is_body else ""}')

B = np.vstack(body_v) if body_v else np.zeros((0, 9), '<f4')
O = np.vstack(other_v)
os.makedirs('app/src/main/assets', exist_ok=True)
with open('app/src/main/assets/car.bin', 'wb') as fo:
    fo.write(struct.pack('<ii', len(B), len(O)))
    fo.write(B.tobytes())
    fo.write(O.tobytes())
with open('app/src/main/assets/CREDITS.txt', 'w') as fo:
    fo.write('This work is based on "2021 Kia Rio" '
             '(https://sketchfab.com/3d-models/2021-kia-rio-82803d9c4afb4cf2867ef364d31e6528) '
             'by tonielpro520 (https://sketchfab.com/tonielpro520) '
             'licensed under CC-BY-4.0 (http://creativecommons.org/licenses/by/4.0/)\n')
print('car.bin :', (len(B) + len(O)) // 3, 'triangles,', os.path.getsize('app/src/main/assets/car.bin') // 1024, 'Ko')

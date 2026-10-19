import sys, math, glob, os
d = sys.argv[1]
for rf in sorted(glob.glob(os.path.join(d, "*.rust.txt"))):
    name = os.path.basename(rf)[:-9]
    lf = os.path.join(d, name + ".luau.txt")
    R = [l.split() for l in open(rf)]
    L = [l.split() for l in open(lf)]
    mx, first, at = 0, None, 0
    modes = 0
    for k,(r,l) in enumerate(zip(R,L)):
        e = math.dist([float(x) for x in r[2:5]], [float(x) for x in l[2:5]])
        if r[1] != l[1]: modes += 1
        if e > mx: mx, at = e, k
        if first is None and e > 1e-4: first = k
    print(f"{name:13s} max |rust-luau| {mx:.6f} m at frame {at}; first frame over 0.1 mm: {first}; mode diffs {modes}")

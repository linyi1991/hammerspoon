#!/usr/bin/env python3
import os, sys, time, json
import numpy as np
from mss import mss
from PIL import Image
import cv2

"""
用法：
python monster_watch.py <x> <y> <w> <h> <thr_hi> <thr_lo> <interval> <templates_dir> <use_edges(0/1)> <release_frames>

改進點：
- 多尺度：0.55~1.45（步長 0.1）
- 對比增強：CLAHE + 輕度 Gaussian blur
- 雙演算法：TM_CCOEFF_NORMED 與 TM_CCORR_NORMED（二取高）
- 輸出 best.scale 與 best.method 方便你看分數來源
"""

SCALES = [round(s, 2) for s in np.arange(0.55, 1.46, 0.10)]
MIN_TPL_W, MIN_TPL_H = 14, 14

def to_gray(img_bgr):
    return cv2.cvtColor(img_bgr, cv2.COLOR_BGR2GRAY)

def enhance(gray, use_edges: bool):
    # 可選邊緣，預設灰階 + CLAHE + 輕度模糊
    if use_edges:
        g = cv2.Canny(gray, 60, 160)
        return g
    clahe = cv2.createCLAHE(clipLimit=2.0, tileGridSize=(8,8))
    g = clahe.apply(gray)
    g = cv2.GaussianBlur(g, (3,3), 0)
    return g

def load_templates(tdir: str, use_edges: bool):
    tmpls = []  # (id, tpl_gray, scale, mask_or_None, name)
    for fn in sorted(os.listdir(tdir)):
        if not fn.lower().endswith((".png",".jpg",".jpeg")): 
            continue
        path = os.path.join(tdir, fn)
        mob_id = os.path.basename(fn).split("_")[0]
        base = cv2.imread(path, cv2.IMREAD_COLOR)
        if base is None: 
            continue
        base_g = to_gray(base)

        # 建立一個「關鍵區域」的遮罩（自動忽略近乎純色背景）
        # 這個 mask 供 CCORR_NORMED 使用，提高對前景的權重
        _, mask = cv2.threshold(base_g, 0, 255, cv2.THRESH_OTSU)
        mask = cv2.bitwise_not(mask)  # 讓前景(較暗的輪廓)權重大一點
        for s in SCALES:
            tw = int(round(base.shape[1] * s))
            th = int(round(base.shape[0] * s))
            if tw < MIN_TPL_W or th < MIN_TPL_H:
                continue
            tpl = cv2.resize(base, (tw, th), interpolation=cv2.INTER_AREA if s < 1.0 else cv2.INTER_LINEAR)
            tpl_g = enhance(to_gray(tpl), use_edges)
            msk = cv2.resize(mask, (tw, th), interpolation=cv2.INTER_NEAREST)
            tmpls.append((mob_id, tpl_g, s, msk, fn))
    return tmpls

def main():
    if len(sys.argv) < 11:
        print(json.dumps({"error":"usage: x y w h thr_hi thr_lo interval tdir use_edges(0/1) release_frames"}), flush=True)
        sys.exit(1)

    x, y, w, h = map(int, sys.argv[1:5])
    thr_hi = float(sys.argv[5])
    thr_lo = float(sys.argv[6])
    interval = float(sys.argv[7])
    tdir = sys.argv[8]
    use_edges = bool(int(sys.argv[9]))
    release_need = int(sys.argv[10])

    if w <= 0 or h <= 0:
        print(json.dumps({"error":"ROI width/height must be > 0"}), flush=True); sys.exit(1)
    if not os.path.isdir(tdir):
        print(json.dumps({"error": f"templates_dir not found: {tdir}"}), flush=True); sys.exit(1)

    tmpls = load_templates(tdir, use_edges)
    if not tmpls:
        print(json.dumps({"error":"no templates loaded"}), flush=True); sys.exit(1)

    locked = False
    below_count = 0
    best_id_locked = None

    with mss() as sct:
        while True:
            t0 = time.time()
            region = {"left": x, "top": y, "width": w, "height": h}
            img = sct.grab(region)
            frame = Image.frombytes("RGB", img.size, img.rgb)
            bgr = cv2.cvtColor(np.array(frame), cv2.COLOR_RGB2BGR)

            g0 = to_gray(bgr)
            g = enhance(g0, use_edges)
            gh, gw = g.shape[:2]

            best = {
                "score": -1.0, "id": None, "loc": (0,0),
                "scale": 1.0, "method": "none", "tplName": ""
            }

            for mob_id, tpl, scale, mask, name in tmpls:
                th, tw = tpl.shape[:2]
                if gh < th or gw < tw:
                    continue

                # 兩種方法取較大者
                # 1) CCOEFF_NORMED（普遍穩定）
                res = cv2.matchTemplate(g, tpl, cv2.TM_CCOEFF_NORMED)
                _, v1, _, l1 = cv2.minMaxLoc(res)

                # 2) CCORR_NORMED + mask（對前景較友善）
                try:
                    res2 = cv2.matchTemplate(g, tpl, cv2.TM_CCORR_NORMED, mask=mask)
                    _, v2, _, l2 = cv2.minMaxLoc(res2)
                except Exception:
                    v2, l2 = -1.0, (0,0)

                if v1 >= v2:
                    v, loc, mname = v1, l1, "CCOEFF"
                else:
                    v, loc, mname = v2, l2, "CCORR_MASK"

                if v > best["score"]:
                    best.update({
                        "score": float(v),
                        "id": mob_id,
                        "loc": loc,
                        "scale": float(scale),
                        "method": mname,
                        "tplName": name
                    })

            # 滯後
            if not locked:
                if best["score"] >= thr_hi:
                    locked, best_id_locked, below_count = True, best["id"], 0
            else:
                if best["score"] < thr_lo or (best_id_locked and best["id"] != best_id_locked):
                    below_count += 1
                    if below_count >= release_need:
                        locked, best_id_locked, below_count = False, None, 0
                else:
                    below_count = 0

            posAbs = {"x": x + best["loc"][0], "y": y + best["loc"][1]}
            print(json.dumps({
                "found": bool((best["score"] >= thr_hi) or locked),
                "best": {
                    "id": best["id"], "score": round(best["score"],4),
                    "pos": posAbs, "scale": best["scale"], "method": best["method"],
                    "tpl": best["tplName"]
                },
                "locked": locked,
                "ts": time.time()
            }), flush=True)

            time.sleep(max(0.0, interval - (time.time() - t0)))

if __name__ == "__main__":
    main()

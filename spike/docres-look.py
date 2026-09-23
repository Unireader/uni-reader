"""DocRes 样张：对 ../in/*.png 跑 appearance / deshadowing / deblurring，以及 deblurring→appearance 串联。
2026-09-23 调研用，结论见 SCAN-ENHANCE-PLAN.md §3（结论：不值得接入）。
准备（目录布局与步骤详见该文档 §3.3）：把本文件复制成 DocRes 代码目录里的 run.py，结果写到 ../out/。
用法（在 DocRes 代码目录）：.venv/bin/python run.py [--cpu]
- 不需要 mbd.pkl：那只给 dewarping 用，这里把它的模块换成空壳。
- 默认用 MPS（Apple GPU，fp16，与官方代码一致）；--cpu 时改用 fp32（CPU 上 fp16 卷积常不支持）。
"""
import os, sys, time, types, argparse, glob
import cv2
import torch

HERE = os.path.dirname(os.path.abspath(__file__))
os.chdir(HERE)
sys.path.insert(0, HERE)

# inference.py 顶层 import 了 dewarping 用的 MBD 模块，这里给个空壳，免得去找 mbd.pkl 和那一堆代码
stub = types.ModuleType("data.MBD.infer")
stub.net1_net2_infer_single_im = lambda *a, **k: (_ for _ in ()).throw(RuntimeError("dewarping 未启用"))
sys.modules["data.MBD"] = types.ModuleType("data.MBD")
sys.modules["data.MBD.infer"] = stub

ap = argparse.ArgumentParser()
ap.add_argument("--cpu", action="store_true")
opt = ap.parse_args()

if opt.cpu:
    # 官方代码把 .half() 写死在各任务函数里；CPU 上改成原样返回（即 fp32）
    torch.Tensor.half = lambda self: self
    torch.nn.Module.half = lambda self: self
    device = torch.device("cpu")
else:
    if not torch.backends.mps.is_available():
        sys.exit("MPS 不可用，加 --cpu 再试")
    device = torch.device("mps")

import inference as inf  # noqa: E402

inf.DEVICE = device
# 官方 model_init 在非 CPU 设备上写死 map_location='cuda:0'，这里照它的结构自己建：先载到 CPU 再挪到 MPS
from models import restormer_arch  # noqa: E402
from utils import convert_state_dict  # noqa: E402
model = restormer_arch.Restormer(inp_channels=6, out_channels=3, dim=48, num_blocks=[2, 3, 3, 4],
                                 num_refinement_blocks=4, heads=[1, 2, 4, 8], ffn_expansion_factor=2.66,
                                 bias=False, LayerNorm_type="WithBias", dual_pixel_task=True)
state = torch.load("./checkpoints/docres.pkl", map_location="cpu", weights_only=False)["model_state"]
model.load_state_dict(convert_state_dict(state))
model.eval()
model = model.to(device)

out_dir = os.path.join(HERE, "..", "out")
os.makedirs(out_dir, exist_ok=True)


def sync():
    if device.type == "mps":
        torch.mps.synchronize()


for path in sorted(glob.glob(os.path.join(HERE, "..", "in", "*.png"))):
    name = os.path.splitext(os.path.basename(path))[0]
    for task in ["appearance", "deshadowing", "deblurring"]:
        t0 = time.time()
        *_, out = inf.inference_one_im(model, path, task)
        sync()
        dt = time.time() - t0
        cv2.imwrite(os.path.join(out_dir, f"{name}_docres_{task}.png"), out)
        print(f"{name} {task}: {dt:.2f}s  {out.shape[1]}x{out.shape[0]}")
    # 串联：先去模糊，再做外观增强（去底色）
    mid = os.path.join(out_dir, f"{name}_docres_deblurring.png")
    t0 = time.time()
    *_, out = inf.inference_one_im(model, mid, "appearance")
    sync()
    cv2.imwrite(os.path.join(out_dir, f"{name}_docres_deblur+appearance.png"), out)
    print(f"{name} deblurring→appearance（第二步）: {time.time() - t0:.2f}s")

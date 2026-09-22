#!/usr/bin/python3
"""
为 indicator-sysmonitor 采集并输出 CPU 与 NVIDIA GPU 状态

CPU 组包含占用率、温度、内存占用率和封装功耗，GPU 组包含占用率、温度、
显存占用率和功耗，缺失指标显示 N/A
使用 psutil 采集系统状态，通过 Linux powercap 和 nvidia-smi 获取功耗
"""

from __future__ import annotations

import math
from pathlib import Path
import subprocess
import time

import psutil


def format_value(value: float | None, unit: str) -> str:
    """
    格式化读数并附加单位

    Args:
        value (float | None): 原始读数，None、NaN 和无穷值视为缺失
        unit (str): 单位后缀，如 %、°C 或 W

    Returns:
        str: 保留零位小数的数值与单位，无效读数返回 N/A
    """
    if value is None or not math.isfinite(value):
        return "N/A"
    return f"{value:.0f}{unit}"


def cpu_temperature() -> float | None:
    """
    读取 CPU 温度，依次选择 Intel 封装 0、AMD Tdie 和 Tctl

    Returns:
        float | None: 温度（°C），读取失败或没有匹配的 CPU 传感器时返回 None
    """
    try:
        sensors = psutil.sensors_temperatures()
    except OSError:
        return None
    for driver, label in (
        ("coretemp", "Package id 0"),
        ("k10temp", "Tdie"),
        ("k10temp", "Tctl"),
    ):
        for sensor in sensors.get(driver, []):
            if sensor.label == label:
                return sensor.current
    return None


def cpu_energy_sample() -> tuple[Path, int, int, float] | None:
    """
    读取 CPU 封装 0 的能量计数，作为功耗计算的起点

    仅匹配 package-0，避免将核心、DRAM 等子域重复计入封装能量

    Returns:
        tuple[Path, int, int, float] | None: 依次为能量文件路径、当前能量（μJ）、
            计数范围（μJ）、单调时钟时刻（秒），没有可读且有效的采样时返回 None
    """
    for zone in sorted(Path("/sys/class/powercap").glob("*:*")):
        try:
            if (zone / "name").read_text().strip() != "package-0":
                continue
            energy_file = zone / "energy_uj"
            maximum = int((zone / "max_energy_range_uj").read_text())
            energy = int(energy_file.read_text())
            if maximum > 0 and 0 <= energy <= maximum:
                return energy_file, energy, maximum, time.monotonic()
        except (OSError, ValueError):
            continue
    return None


def cpu_power(sample: tuple[Path, int, int, float] | None) -> float | None:
    """
    根据两次能量采样计算 CPU 封装平均功耗

    采样间隔内计数器不得重置，且能量增量须小于一个计数范围

    Args:
        sample (tuple[Path, int, int, float] | None): cpu_energy_sample 的返回值，
            应在起始采样后等待一段时间再调用本函数

    Returns:
        float | None: 平均功耗（W），采样缺失、读取失败、当前计数越界或
            采样间隔非正时返回 None
    """
    if sample is None:
        return None
    energy_file, before, maximum, started = sample
    try:
        after = int(energy_file.read_text())
    except (OSError, ValueError):
        return None
    elapsed = time.monotonic() - started
    if elapsed <= 0 or not 0 <= after <= maximum:
        return None
    delta = after - before
    # 负差值按一次回绕修正，无法据此识别计数器被外部重置
    if delta < 0:
        delta += maximum
    return delta / 1_000_000 / elapsed


def gpu_status() -> tuple[float | None, float | None, float | None, float | None]:
    """
    通过一次 nvidia-smi 查询获取 NVIDIA GPU 0 的状态

    查询最多等待 1 秒，失败或响应字段数不符时返回四个 None
    单个字段无效时保留其他可用指标，显存占用率需要有效用量及大于零的总量

    Returns:
        tuple[float | None, float | None, float | None, float | None]:
            依次为 GPU 占用率（%）、温度（°C）、显存容量占用率（%）和功耗（W），
            不可用项为 None
    """
    try:
        result = subprocess.run(
            [
                "nvidia-smi", "--id=0",
                "--query-gpu=utilization.gpu,temperature.gpu,memory.used,memory.total,power.draw",
                "--format=csv,noheader,nounits",
            ],
            capture_output=True, text=True, check=True, timeout=1,
        )
    except (OSError, subprocess.SubprocessError):
        return None, None, None, None

    fields = result.stdout.strip().split(",")
    if len(fields) != 5:
        return None, None, None, None
    values: list[float | None] = []
    for field in fields:
        try:
            value = float(field.strip())
            values.append(value if math.isfinite(value) and value >= 0 else None)
        except ValueError:
            values.append(None)
    usage, temperature, used, total, power = values
    # 显存显示已用容量占比，区别于显存访问忙碌率 utilization.memory
    memory = used * 100 / total if used is not None and total is not None and total > 0 else None
    return usage, temperature, memory, power


def main() -> None:
    """
    输出一行 CPU 与 GPU 状态供顶栏显示

    CPU 占用率采样等待 0.2 秒，封装功耗复用同一等待窗口
    各组依次显示占用率、温度、功耗，末尾标注 RAM 或 VRAM 占用率
    """
    energy = cpu_energy_sample()
    cpu = psutil.cpu_percent(interval=0.2)
    power = cpu_power(energy)
    temperature = cpu_temperature()
    memory = psutil.virtual_memory().percent
    gpu, gpu_temperature, gpu_memory, gpu_power = gpu_status()
    print(
        f"CPU {format_value(cpu, '%')} {format_value(temperature, '°C')} "
        f"{format_value(power, 'W')} · RAM {format_value(memory, '%')} │ "
        f"GPU {format_value(gpu, '%')} {format_value(gpu_temperature, '°C')} "
        f"{format_value(gpu_power, 'W')} · VRAM {format_value(gpu_memory, '%')}"
    )


if __name__ == "__main__":
    main()

# 一阶巴特沃斯低通滤波器：从模拟到 `iir_lpf_ema`

对应硬件模块：[`iir_lpf_ema.v`](../project_1.srcs/sources_1/new/iir_lpf_ema.v)

核心递推：

$$
y[n] = y[n-1] + \bigl(x[n] - y[n-1]\bigr)\cdot 2^{-k}
$$

下文说明：**一阶巴特沃斯模拟低通 → 离散 IIR → 指数移动平均（EMA）→ 本模块的移位实现**，并给出截止频率与 `shift_k` 的对应关系。

---

## 1. 一阶巴特沃斯模拟原型

$N$ 阶巴特沃斯低通的幅度平方响应为

$$
|H(j\omega)|^2 = \frac{1}{1 + (\omega/\omega_c)^{2N}}
$$

当 **$N=1$** 时：

$$
|H(j\omega)|^2 = \frac{1}{1 + (\omega/\omega_c)^2}
$$

对应的因果稳定传递函数（归一化后）为

$$
H(s) = \frac{\omega_c}{s + \omega_c}
$$

这与一阶 RC 低通完全相同：

$$
H_{\mathrm{RC}}(s) = \frac{1}{1 + sRC},\qquad \omega_c = \frac{1}{RC}
$$

因此：

- **一阶巴特沃斯 ≡ 一阶 RC ≡ 单极点低通**
- 通带最平坦在 $N=1$ 时并无额外自由度；“巴特沃斯”标签在一阶时与 RC 无区别
- 阻带斜率为 **-6 dB/oct**（-20 dB/dec）

幅频与相位：

$$
|H(j\omega)| = \frac{1}{\sqrt{1+(\omega/\omega_c)^2}},\qquad
\angle H(j\omega) = -\arctan(\omega/\omega_c)
$$

在 $\omega=\omega_c$ 处：$|H|=1/\sqrt{2}$（-3 dB），相位 $-45^\circ$。

---

## 2. 从连续到离散：前向欧拉 / 后向欧拉

设采样周期为 $T_s$（本工程中对应 CIC 降采样后的有效节拍，由 `en` 触发）。

### 2.1 后向欧拉（Backward Euler）

用 $s \approx (1 - z^{-1})/T_s$ 代入 $H(s)=\omega_c/(s+\omega_c)$：

$$
H(z) = \frac{\omega_c}{\dfrac{1-z^{-1}}{T_s}+\omega_c}
= \frac{\omega_c T_s}{1 + \omega_c T_s - z^{-1}}
$$

令

$$
\alpha = \frac{\omega_c T_s}{1 + \omega_c T_s}
\quad\Rightarrow\quad
1-\alpha = \frac{1}{1+\omega_c T_s}
$$

则

$$
H(z) = \frac{\alpha}{1 - (1-\alpha)\,z^{-1}}
$$

时域递推：

$$
y[n] = (1-\alpha)\,y[n-1] + \alpha\,x[n]
$$

整理为增量形式：

$$
y[n] = y[n-1] + \alpha\bigl(x[n] - y[n-1]\bigr)
$$

这正是 **指数移动平均（EMA）**，也是 `iir_lpf_ema` 的算法。

### 2.2 与双线性变换的关系（一阶时）

双线性变换 $s = \dfrac{2}{T_s}\dfrac{1-z^{-1}}{1+z^{-1}}$ 对一阶同样得到单极点 IIR，系数不同，但结构仍是

$$
y[n] = a\,y[n-1] + b\bigl(x[n] + x[n-1]\bigr)
$$

工程上锁相放大器后级更常用 **EMA / 一阶 RC 离散化**（无前馈对称项、单调收敛、实现极简）。本模块采用 EMA 形式，在一阶意义下与巴特沃斯/RC 等价。

---

## 3. 与硬件参数 $\alpha = 2^{-k}$ 的对应

模块用移位实现乘法，取

$$
\alpha = 2^{-k},\qquad k = \texttt{shift\_k}
$$

递推变为

$$
y[n] = y[n-1] + \bigl(x[n]-y[n-1]\bigr)\gg k
$$

（有符号算术右移，对应 Verilog 中的 `>>>`。）

### 3.1 截止角频率 / 时间常数

由后向欧拉关系 $\alpha = \omega_c T_s / (1+\omega_c T_s)$ 反解：

$$
\omega_c = \frac{\alpha}{(1-\alpha)\,T_s}
$$

当 $\alpha \ll 1$（窄带、大 $k$）时：

$$
\omega_c \approx \frac{\alpha}{T_s} = \frac{2^{-k}}{T_s},\qquad
f_c = \frac{\omega_c}{2\pi} \approx \frac{2^{-k}}{2\pi\,T_s}
$$

等效模拟时间常数：

$$
\tau = \frac{1}{\omega_c} \approx \frac{T_s}{\alpha} = T_s\cdot 2^{k}
$$

| $k$ (`shift_k`) | $\alpha$ | $\tau / T_s$（约） | 说明 |
|----------------:|---------:|-------------------:|------|
| 0 | 1 | 1 | 几乎直通 |
| 4 | $1/16$ | 16 | 较宽 |
| 8 | $1/256$ | 256 | 常用量级 |
| 12 | $1/4096$ | 4096 | 窄带 |
| 16 | $1/65536$ | $6.55\times10^4$ | 极窄 |
| 20 | $2^{-20}$ | $\sim10^6$ | 极慢收敛 |

实际 $-3\,\mathrm{dB}$ 数字截止频率更精确地由 $|H(e^{j\Omega})|=1/\sqrt{2}$ 求解（$\Omega=\omega T_s$）。对

$$
H(z)=\frac{\alpha}{1-(1-\alpha)z^{-1}}
$$

有

$$
\cos\Omega_c = 1 - \frac{\alpha^2}{2(1-\alpha)}
$$

当 $\alpha\ll 1$ 时 $\Omega_c\approx\alpha$，与 $f_c\approx\alpha/(2\pi T_s)$ 一致。

### 3.2 噪声带宽（简述）

等效噪声带宽（单边，相对白噪声）约为

$$
B_n \approx \frac{\alpha}{2}\,f_s = \frac{f_s}{2^{k+1}}
$$

（$f_s=1/T_s$ 为 `en` 有效采样率。）$k$ 每加 1，$B_n$ 减半，SNR 理论上约 +3 dB（对白噪声）。

稳定时间的完整推导见下一节。

---

## 4. 输出稳定时间：详细推导

“稳定”需要先定义：**相对稳态误差落在容差 $\varepsilon$ 以内**。下文从差分方程出发，给出一阶 EMA 与 $N$ 阶级联的精确公式、常用近似与工程速查表。

### 4.1 一阶递推的闭式解

滤波器：

$$
y[n] = (1-\alpha)\,y[n-1] + \alpha\,x[n],\qquad \alpha = 2^{-k}
$$

设初值 $y[-1]=y_0$（复位后通常 $y_0=0$），输入为幅度 $A$ 的阶跃 $x[n]=A$（$n\ge 0$）。

齐次解：$y_h[n] = C\,(1-\alpha)^n$。  
特解（稳态）：$y_\infty = A$（因 DC 增益为 1）。  
通解：$y[n] = A + C\,(1-\alpha)^n$。

由 $n=0$：$y[0]=(1-\alpha)y_0+\alpha A$，或等价地用递推归纳，得

$$
\boxed{
y[n] = A + (y_0 - A)\,(1-\alpha)^{n+1}
\quad\text{（若按 }y[n]=(1-\alpha)y[n-1]+\alpha A\text{，}n\ge0\text{，}y[-1]=y_0\text{）}
}
$$

更常见写法（令输出从 $n=0$ 起、且 $y[-1]=0$）：

$$
y[n] = A\bigl(1 - (1-\alpha)^{n+1}\bigr)
$$

许多教材把下标写成从第一次更新后算起，等价地记

$$
y[n] = A\bigl(1 - (1-\alpha)^n\bigr)
\quad\text{（}y[0]=0\text{ 初值约定下，}n\text{ 为更新次数）}
$$

下文统一采用：**$n$ = `en` 有效更新次数**，且

$$
y[n] = A\bigl(1 - (1-\alpha)^n\bigr),\qquad y[0]=0
$$

（$n=0$ 表示尚未更新；第 $n$ 次 `en` 之后为上式。）

### 4.2 相对误差与稳定判据

相对稳态误差：

$$
e[n] = \frac{A - y[n]}{A} = (1-\alpha)^n
$$

定义稳定：存在 $n_\varepsilon$，使得

$$
e[n_\varepsilon] \le \varepsilon
\quad\Leftrightarrow\quad
(1-\alpha)^{n_\varepsilon} \le \varepsilon
$$

取自然对数（$0<\alpha\le 1$，$1-\alpha>0$）：

$$
n_\varepsilon \ln(1-\alpha) \le \ln\varepsilon
$$

因 $\ln(1-\alpha)<0$，不等式变号：

$$
\boxed{
n_\varepsilon = \left\lceil
\frac{\ln\varepsilon}{\ln(1-\alpha)}
\right\rceil
}
$$

对应物理时间（$T_s$ 为两次 `en` 的间隔）：

$$
\boxed{
t_\varepsilon = n_\varepsilon\, T_s
}
$$

### 4.3 常用近似（$\alpha\ll 1$）

当 $k$ 较大（$\alpha=2^{-k}\ll 1$）时，

$$
\ln(1-\alpha) = -\alpha - \frac{\alpha^2}{2} - \frac{\alpha^3}{3} - \cdots \approx -\alpha
$$

于是

$$
n_\varepsilon \approx \frac{-\ln\varepsilon}{\alpha} = (-\ln\varepsilon)\,2^{k}
$$

常用容差与倍数：

| 容差 $\varepsilon$ | 含义 | $-\ln\varepsilon$ | $n_\varepsilon$（精确） | $n_\varepsilon$（$\alpha\ll1$ 近似） |
|-------------------:|------|------------------:|------------------------:|-------------------------------------:|
| $e^{-1}\approx 0.368$ | 到 $63.2\%$（1 个时间常数） | 1 | $\dfrac{\ln(1-\alpha)^{-1}}{-\ln(1-\alpha)}$ | $2^{k}$ |
| $0.1$ | 到 $90\%$ | $\ln 10\approx 2.303$ | 同上公式 | $\approx 2.30\cdot 2^{k}$ |
| $0.05$ | 到 $95\%$ | $\approx 3.00$ | | $\approx 3.00\cdot 2^{k}$ |
| $e^{-3}\approx 0.050$ | $\approx 95\%$（3$\tau$） | 3 | | $3\cdot 2^{k}$ |
| $0.01$ | 到 $99\%$ | $\ln 100\approx 4.605$ | | $\approx 4.61\cdot 2^{k}$ |
| $e^{-5}\approx 0.0067$ | $\approx 99.3\%$（5$\tau$） | 5 | | $5\cdot 2^{k}$ |
| $0.001$ | 到 $99.9\%$ | $\ln 1000\approx 6.907$ | | $\approx 6.91\cdot 2^{k}$ |

与模拟一阶系统对照：$\tau\approx T_s/\alpha = T_s\cdot 2^{k}$，则

$$
t_\varepsilon \approx (-\ln\varepsilon)\,\tau
$$

与 RC 充电曲线 $1-e^{-t/\tau}$ 完全一致（离散在 $\alpha\ll 1$ 时逼近连续）。

### 4.4 精确式与近似式的误差

对有限 $\alpha$，更精确的展开：

$$
\frac{\ln\varepsilon}{\ln(1-\alpha)}
= \frac{-\ln\varepsilon}{\alpha}\cdot\frac{\alpha}{-\ln(1-\alpha)}
= \frac{-\ln\varepsilon}{\alpha}\cdot\frac{1}{1+\alpha/2+\alpha^2/3+\cdots}
$$

故近似 $n\approx(-\ln\varepsilon)/\alpha$ **略偏大**（偏保守）。例如 $\alpha=1/16$（$k=4$），因子 $1/(-\ln(1-\alpha)/\alpha)\approx 0.968$，误差约 3%。

### 4.5 非零初值 / 阶跃跳变

若滤波器已稳定在 $A_1$，输入跳到 $A_2$，则

$$
y[n] = A_2 + (A_1-A_2)\,(1-\alpha)^n
$$

相对新稳态的误差仍是 $(1-\alpha)^n$，**稳定所需更新次数与初值无关**，只取决于 $\alpha$ 与 $\varepsilon$：

$$
n_\varepsilon = \left\lceil\frac{\ln\varepsilon}{\ln(1-\alpha)}\right\rceil
$$

绝对误差为 $|A_2-A_1|\,(1-\alpha)^n$；若用绝对容差 $\delta$（而非相对 $\varepsilon$），则

$$
n_\delta = \left\lceil\frac{\ln\bigl(\delta/|A_2-A_1|\bigr)}{\ln(1-\alpha)}\right\rceil
$$

锁相放大器中幅度可能差几个数量级，定标时注意区分相对/绝对判据。

### 4.6 $N$ 阶级联（`iir_lpf_cascade`）的稳定时间

$N$ 个相同极点级联时，连续域阶跃响应为不完全伽马形式：

$$
\frac{y(t)}{A} = 1 - e^{-t/\tau}\sum_{m=0}^{N-1}\frac{(t/\tau)^m}{m!}
$$

离散域（相同 $\alpha$，每级更新一次）在 $\alpha\ll 1$ 时可用上式，$t=n T_s$，$\tau=T_s/\alpha$。

令残余 $r_N(u)=e^{-u}\sum_{m=0}^{N-1}u^m/m!$，$u=t/\tau$，求最小 $u$ 使 $r_N(u)\le\varepsilon$。

对常用 $\varepsilon=0.01$（到 99%），数值结果约为：

| 阶数 $N$ | $u_{1\%}=t/\tau$ | $n\approx u\cdot 2^{k}$（$\alpha\ll1$） | 相对一阶倍数 |
|--------:|-----------------:|----------------------------------------:|-------------:|
| 1 | $\approx 4.61$ | $\approx 4.61\cdot 2^{k}$ | 1.0× |
| 2 | $\approx 6.64$ | $\approx 6.64\cdot 2^{k}$ | $\approx 1.44\times$ |
| 3 | $\approx 8.41$ | $\approx 8.41\cdot 2^{k}$ | $\approx 1.82\times$ |
| 4 | $\approx 9.98$ | $\approx 9.98\cdot 2^{k}$ | $\approx 2.17\times$ |

要点：

- 提高 `order` 会 **拉长** 稳定时间（同 $k$ 下约到原来的 1.4～2.2 倍，对 1% 判据）
- 级联后 $-3\,\mathrm{dB}$ 带宽也会变窄；若要保持相近带宽，需略减小 $k$，稳定时间再重新用上表估算
- 商用 LIA 手册中的 “wait $5\times$ time constant” 等多针对一阶；多阶应按上表或仿真加长等待

一阶精确离散式无需连续近似；多阶闭式可用生成函数，但工程上用连续近似或直接仿真 `iir_lpf_cascade` 阶跃即可。

### 4.7 工程速查表（一阶，$\varepsilon=1\%$）

$n_{1\%}\approx 4.61\cdot 2^{k}$，$t_{1\%}=n_{1\%}T_s$。

| $k$ | $\alpha$ | $n_{1\%}$（约） | 若 $T_s=1\,\mathrm{ms}$ | 若 $T_s=100\,\mu\mathrm{s}$ |
|----:|---------:|----------------:|------------------------:|----------------------------:|
| 8 | $1/256$ | $\sim 1.2\times 10^{3}$ | $\sim 1.2\,\mathrm{s}$ | $\sim 0.12\,\mathrm{s}$ |
| 10 | $1/1024$ | $\sim 4.7\times 10^{3}$ | $\sim 4.7\,\mathrm{s}$ | $\sim 0.47\,\mathrm{s}$ |
| 12 | $1/4096$ | $\sim 1.9\times 10^{4}$ | $\sim 19\,\mathrm{s}$ | $\sim 1.9\,\mathrm{s}$ |
| 14 | $1/16384$ | $\sim 7.5\times 10^{4}$ | $\sim 75\,\mathrm{s}$ | $\sim 7.5\,\mathrm{s}$ |
| 16 | $1/65536$ | $\sim 3.0\times 10^{5}$ | $\sim 5.0\,\mathrm{min}$ | $\sim 30\,\mathrm{s}$ |
| 20 | $2^{-20}$ | $\sim 4.8\times 10^{6}$ | $\sim 1.3\,\mathrm{h}$ | $\sim 8\,\mathrm{min}$ |

**务必用 CIC 后的有效 $T_s$，不要用系统时钟周期。**

### 4.8 与模拟 $\tau$ 的一句话对照

$$
\tau \approx T_s\cdot 2^{k},\qquad
t_{\varepsilon} \approx (-\ln\varepsilon)\,\tau
\quad\text{（一阶）}
$$

例：要 99% 稳定（$\varepsilon=0.01$），等待约 **$4.6\,\tau$**；要到 $1-e^{-5}\approx 99.3\%$，等待约 **$5\,\tau$**。

---

## 5. 硬件实现要点（对照代码）

### 5.1 定点扩展

```verilog
localparam ACC_WIDTH = IN_WIDTH + FRAC_WIDTH;
assign din_scaled = {din, {FRAC_WIDTH{1'b0}}};  // 等价于 din * 2^FRAC_WIDTH
```

内部累加器把原整数信号左移 `FRAC_WIDTH` 位，低位作小数。这样 $\alpha=2^{-k}$ 的右移不会在整数域直接截成 0（避免“死区”）。

要求：**`FRAC_WIDTH ≥ 最大使用的 k`**，否则小增益更新被截断，滤波器卡住。

### 5.2 有符号算术右移

```verilog
assign diff = din_scaled - y_acc;
assign diff_shifted = diff >>> shift_k_safe;
y_acc <= y_acc + diff_shifted;
```

即：

$$
y_{\mathrm{acc}}[n] = y_{\mathrm{acc}}[n-1] + \bigl(x_{\mathrm{scaled}}[n] - y_{\mathrm{acc}}[n-1]\bigr)\cdot 2^{-k}
$$

`>>>` 保证负数正确符号扩展。

### 5.3 移位上限钳位

```verilog
localparam SHIFT_MAX = ACC_WIDTH - 1;
wire [4:0] shift_k_safe = (shift_k > SHIFT_MAX[4:0]) ? SHIFT_MAX[4:0] : shift_k;
```

若 $k \ge \texttt{ACC\_WIDTH}$，有符号右移会变成全符号位，更新量恒为 0 或 -1 量级异常，滤波器“死锁”。钳位保证 $k\le\texttt{ACC\_WIDTH}-1$。

### 5.4 输出舍入

```verilog
dout <= (y_acc + diff_shifted + {1'b0, 1'b1, {(FRAC_WIDTH-1){1'b0}}}) >>> FRAC_WIDTH;
```

在丢掉小数位前加 $2^{\texttt{FRAC\_WIDTH}-1}$（半个 LSB），实现四舍五入，减轻截断偏置与极限环振荡。

### 5.5 使能节拍

更新仅在 `en=1` 时发生，故 $T_s$ 是 **CIC 降采样后的数据间隔**，不是系统 `clk` 周期。计算 $f_c$、$\tau$ 时必须用该有效采样率。

---

## 6. 传递函数小结

| 域 | 表达式 |
|----|--------|
| 模拟（一阶巴特沃斯 / RC） | $H(s)=\dfrac{\omega_c}{s+\omega_c}$ |
| 离散 EMA | $H(z)=\dfrac{\alpha}{1-(1-\alpha)z^{-1}}$，$\alpha=2^{-k}$ |
| 差分方程 | $y[n]=y[n-1]+\alpha\bigl(x[n]-y[n-1]\bigr)$ |
| 极点 | $z_p=1-\alpha$（单位圆内，$\alpha\in(0,1]$ 时稳定） |
| DC 增益 | $H(1)=1$（无偏直流提取） |

零频率处增益为 1，适合锁相放大器提取直流 / 近直流分量。

---

## 7. 与级联多阶（`iir_lpf_cascade`）的区别

[`iir_lpf_cascade.v`](../project_1.srcs/sources_1/new/iir_lpf_cascade.v) 将 $N$ 个相同 $\alpha$ 的一阶级联：

$$
H_N(z) = \left[\frac{\alpha}{1-(1-\alpha)z^{-1}}\right]^{N}
$$

| | 一阶 EMA（本模块） | 相同极点级联 | 真正的 $N$ 阶巴特沃斯 |
|--|-------------------|-------------|----------------------|
| 阻带斜率 | 6 dB/oct | $6N$ dB/oct | $6N$ dB/oct |
| 极点 | 1 个实极点 | $N$ 个重合实极点 | 共轭复极点（$N\ge2$） |
| 通带 | 单调 | 单调、更缓 | 最平坦 |
| 阶跃 | 无过冲 | 无过冲 | $N\ge2$ 可有振铃 |
| 实现 | 移位累加 | 复用本模块 | 需更复杂系数 |

商用锁相放大器（如 SR830）的 6/12/18/24 dB/oct 选项，通常是 **相同时间常数的一阶 RC 级联**，而不是高阶巴特沃斯。本工程与该做法一致。

---

## 8. 设计选用速查

1. 已知有效采样周期 $T_s$ 与目标时间常数 $\tau$：取 $k\approx\log_2(\tau/T_s)$，再细调。
2. 已知目标噪声带宽 $B_n$：取 $k\approx\log_2(f_s/(2B_n))$。
3. 确认 `FRAC_WIDTH ≥ k_max`，且 `IN_WIDTH + FRAC_WIDTH - 1 ≥ k_max`。
4. 需要更陡阻带、仍要单调收敛：用 `iir_lpf_cascade` 提高 `order`，各级共用同一 `shift_k`（注意总带宽会随阶数变窄，必要时略减小 $k$）。
5. 稳定等待时间：一阶用 $t_\varepsilon\approx(-\ln\varepsilon)\,T_s\cdot 2^{k}$；多阶见 §4.6，勿简单套用 $5\tau$。

---

## 参考文献与记号

- Oppenheim & Schafer, *Discrete-Time Signal Processing* — IIR 离散化与频率响应
- 一阶巴特沃斯原型：$H(s)=\omega_c/(s+\omega_c)$
- 本仓库实现：`y += (x-y) >>> k`，即 $\alpha=2^{-k}$ 的 EMA
- 稳定时间：相对误差 $e[n]=(1-\alpha)^n$，见 §4

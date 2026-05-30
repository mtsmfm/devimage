# GPU and WebGPU

## WSL2 Model

On WSL2, `--gpus all` proves CUDA/NVML/NVENC access, not Linux desktop graphics or browser WebGPU. WSL2 graphics reaches the Windows WDDM GPU through:

- `/dev/dxg`
- `/usr/lib/wsl/lib`
- Mesa `d3d12` for OpenGL
- Mesa `dzn` for Vulkan/WebGPU

Do not install Linux NVIDIA GL/Vulkan userland inside WSL2 containers. NVIDIA's Linux driver stack is not the path used by WSL2 graphics.

## Expected Setup

Mount WSL userland and use devimage's patched `dzn`:

```yaml
volumes:
  - "/usr/lib/wsl:/usr/lib/wsl:ro"
environment:
  LD_LIBRARY_PATH: "/opt/mesa-dzn/lib/x86_64-linux-gnu:/usr/lib/wsl/lib"
  GALLIUM_DRIVER: "d3d12"
  VK_DRIVER_FILES: "/opt/mesa-dzn/share/vulkan/icd.d/dzn_icd.x86_64.json"
  MESA_D3D12_DEFAULT_ADAPTER_NAME: "NVIDIA"
```

The patched `dzn` exists because stock Dozen may fail Chromium/Dawn adapter gates:

- Dawn expects `fullDrawIndexUint32`.
- Chrome page WebGPU also needs external-image support, which includes exportable/importable external semaphores in Dawn's Vulkan backend.

## Checks

```bash
test -e /dev/dxg && echo dxg-present
test -d /usr/lib/wsl/lib && echo wsl-lib-mounted
LD_LIBRARY_PATH=/opt/mesa-dzn/lib/x86_64-linux-gnu:/usr/lib/wsl/lib:${LD_LIBRARY_PATH:-} \
VK_DRIVER_FILES=/opt/mesa-dzn/share/vulkan/icd.d/dzn_icd.x86_64.json \
MESA_D3D12_DEFAULT_ADAPTER_NAME=NVIDIA \
vulkaninfo --summary
```

Good Vulkan output mentions `Microsoft Direct3D12 (NVIDIA ...)` and `Dozen`.

Bad outputs:

- `llvmpipe`: CPU Vulkan/OpenGL path.
- `SwiftShader`: Chrome software Vulkan/WebGPU path.
- `requestAdapter()` returns `null`: Dawn/Chrome rejected available adapters.

## Chrome

Use the wrapper:

```bash
devimage-chrome-webgpu chrome://gpu
```

For headless automation:

```bash
DEVIMAGE_CHROME_HEADLESS=true devimage-chrome-webgpu http://127.0.0.1:18000
```

The wrapper sets the dzn environment and Chrome/Dawn flags. Only set `DEVIMAGE_CHROME_IGNORE_CERT_ERRORS=true` when diagnosing TLS setup.

## Playwright

Use Google Chrome, not Playwright's default bundled Chromium, and pass both env and flags:

```ts
const browser = await chromium.launch({
  channel: "chrome",
  headless: true,
  env: {
    ...process.env,
    LD_LIBRARY_PATH: [
      "/opt/mesa-dzn/lib/x86_64-linux-gnu",
      "/usr/lib/wsl/lib",
      process.env.LD_LIBRARY_PATH ?? "",
    ].filter(Boolean).join(":"),
    VK_DRIVER_FILES:
      process.env.VK_DRIVER_FILES ??
      "/opt/mesa-dzn/share/vulkan/icd.d/dzn_icd.x86_64.json",
    MESA_D3D12_DEFAULT_ADAPTER_NAME:
      process.env.MESA_D3D12_DEFAULT_ADAPTER_NAME ?? "NVIDIA",
  },
  args: [
    "--enable-unsafe-webgpu",
    "--enable-webgpu-developer-features",
    "--ignore-gpu-blocklist",
    "--force_high_performance_gpu",
    "--use-gl=angle",
    "--use-angle=vulkan",
    "--enable-features=Vulkan,DefaultANGLEVulkan,VulkanFromANGLE,WebGPU,WebGPUDeveloperFeatures",
    "--enable-dawn-features=allow_unsafe_apis,disable_adapter_blocklist",
    "--disable-dawn-features=disallow_unsafe_apis",
    "--enable-angle-features=exposeES32ForTesting",
    "--disable-vulkan-surface",
  ],
});
```

Verify in page code:

```ts
await page.evaluate(async () => {
  const adapter = await navigator.gpu.requestAdapter({
    powerPreference: "high-performance",
    forceFallbackAdapter: false,
  });
  return adapter && {
    fallback: adapter.isFallbackAdapter,
    features: [...adapter.features],
  };
});
```

Do not add `--disable-gpu`.

# Desktop

## Startup

The desktop stack is intentionally off by default. Start it only when needed:

```bash
devimage-gui start
devimage-gui status
```

Stop it when done:

```bash
devimage-gui stop
```

`DEVIMAGE_ENABLE_GUI=true` starts the GUI bundle at boot.

## Services

`devimage-gui` controls the s6 `gui` bundle:

- `svc-xorg`
- `svc-de`
- `svc-selkies`
- `svc-xsettingsd`
- `svc-pulseaudio`
- `svc-dbus`
- `svc-nginx`

The desktop uses openbox/labwc and Selkies PixelFlux streaming. It is reachable through the published Selkies port when the GUI bundle is up.

## Access

Default container port:

- container `3000`: Selkies HTTP/WebSocket

Typical compose/run mapping:

- host `8080` to container `3000`

Under the throttle overlay, inbound host access is handled by the `ingress` sidecar.

## GUI Automation

Common tools are installed:

- `xdotool`
- `wmctrl`
- `scrot`
- `xclip`

Use screenshots and window inspection when debugging GUI state:

```bash
wmctrl -l
scrot /tmp/devimage-screen.png
```

## Blender, FreeCAD, MCP

Blender and FreeCAD are installed for desktop/MCP work:

- Blender: `/usr/local/bin/blender`
- FreeCAD: `/usr/local/bin/freecad`
- Blender MCP: `/usr/local/bin/blender-mcp`
- FreeCAD MCP: `/usr/local/bin/freecad-mcp`

Register MCP servers for installed agents:

```bash
devimage-mcp setup
```

If Blender viewport is slow on WSL2, check `references/gpu-webgpu.md`; GL may be using `llvmpipe` instead of Mesa `d3d12`.

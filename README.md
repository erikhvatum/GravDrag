# GravDrag
An interactive 2D gravity sandbox macOS game with physics computed in Metal.

## Requirements
- macOS 13 (Ventura) or later
- Xcode 15 or later
- A Mac with Metal support (virtually all Macs from 2012 onward)

## Building
Open `GravDrag.xcodeproj` in Xcode and press ⌘R to build and run.

## Features

### Physics
- N-body gravitational simulation computed entirely on the GPU via a Metal compute shader
- Semi-implicit Euler integration with configurable time step
- Softened gravity to prevent singularities at close range
- Starts with a demo scene of orbiting bodies

### Interaction

| Action | How |
|---|---|
| **Add body** | Select ＋ tool (or press A), click in the canvas |
| **Drag body** | Select ↖ tool (or press S), click and drag a body; release to throw |
| **Delete body** | Select ✕ tool (or press D) and click, or right-click any body, or select then press Delete |
| **Pause / Play** | Press Space or click ⏸ in the toolbar |
| **Reset scene** | Press R |
| **Select all** | ⌘A |
| **Rectangle select** | In Select mode, drag on empty space (▭ button) |
| **Lasso select** | In Select mode, draw freehand around bodies (⌓ button) |
| **Group drag** | Select multiple bodies, then drag any one of them |
| **Control spin** | Select a body, use the spin stepper in the toolbar, or scroll the mouse wheel |
| **Pan camera** | Scroll without modifier |
| **Zoom camera** | Ctrl + scroll |

### Adding Bodies
Choose a shape from the dropdown (Circle, Rectangle, Triangle, or Custom) before clicking in **Add** mode.

### Shape Editor
Click **Custom…** in the shape dropdown to open the Shape Editor panel.  
Click inside the canvas to add polygon vertices. The live preview shows the polygon as it grows.  
When you have ≥ 3 vertices, click **Use Shape** to make it the active add-template.  
The polygon is automatically centred and scaled. Non-convex polygons are handled via ear-clip triangulation.

### Selection
Rectangle and lasso selection are designed for use while the simulation is **paused**.  
Selected bodies are highlighted in yellow and can be:
- Dragged as a group
- Deleted together (Delete key or Edit → Delete Selected)
- Given the same spin (spin stepper or scroll wheel)

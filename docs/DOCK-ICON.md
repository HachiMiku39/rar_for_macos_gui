# Dock icon appearance revision (included in 1.0, build 15)

The previous runtime override used a full-bleed square bitmap. Its visible rectangle and optical size did not match the rounded, inset neighboring Dock icons in the user's screenshot.

This legacy ICNS rendition uses a rounded neutral-grey tile with transparent margins and a restrained shadow. The character/archive-box theme is retained. The original artwork remains at `Resources/AppIcon-source.png`; the edited rendition is `Resources/AppIcon-dock.png`. Rebuild `Resources/AppIcon.icns` with `python3 scripts/build-icon.py`.

This is a static legacy ICNS, not an Icon Composer layered asset. Do not present it as a live Liquid Glass icon or automatically generated appearance variants. Apple's modern layered-icon workflow expects unmasked layers; migrating to that workflow should use separate unmasked assets, not double-mask this ICNS rendition. Reference: https://developer.apple.com/design/human-interface-guidelines/app-icons

## Image editing

Tool: built-in imagegen, transparent background enabled. Edit target: the original project PNG. No external API key used.

Final prompt:

> Use case: precise-object-edit. Asset type: production-ready legacy macOS Dock application icon PNG, square 1024x1024 canvas with real alpha transparency. Edit target: supplied ArchiveDesk artwork. Make only a framing/background treatment change, not a logo redesign. Preserve the same turquoise twin-tail chibi character, expression, pose, red/blue/green archive boxes, belts and file cards, their relative composition and vivid colors, with very high fidelity. Fit the entire original composition within one centered rounded-square tile occupying approximately 82% of the canvas width and height (9% transparent margin each side), using macOS-style continuous rounded corners roughly 22% of tile width. Keep the existing neutral grey background inside the tile, slightly refine it into a subtle satin grey gradient. Clip all art to the rounded tile; don't let hair or objects spill outside. Ensure the face, twin tails and archive boxes remain visible; rescale the composition slightly if necessary to protect the corners. Outside the tile is genuinely transparent, not grey/white/checkerboard. Add only a tiny soft natural drop shadow immediately under the tile, no chunky border, no neon rim, no excessive glass reflection. Output ONLY the isolated finished icon asset, frontal and undistorted; not a mockup, no Dock, no screenshot, no text, no additional objects. The important changes are rounded tile silhouette, balanced transparent margins and smaller optical size so it matches neighboring macOS Dock icons.

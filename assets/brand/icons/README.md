# CCPlayer icons

Created with the built-in image_gen tool from the user-provided Yamada Ryo illustration.

Prompt: preserve the supplied character, remove the white background and lower body, frame the head and upper torso to fill a square, with transparent background and no text or decoration.

- `ryo-master.png`: transparent generated master.
- `windows.png`: 1024px transparent Windows artwork; exported to `windows/runner/resources/app_icon.ico` at 16/24/32/48/64/128/256px.
- `android.png`: 1024px white-background Android artwork; exported to all five launcher densities.
- Android adaptive icons use a white background and a separate transparent foreground, sized for the launcher viewport. The launcher supplies the final mask.
- Run `./assets/brand/icons/export-icons.ps1` from the repository root to regenerate platform PNG/ICO files (Windows PowerShell, System.Drawing).

This character artwork is based on the user-supplied reference; no ownership or licensing rights are implied.

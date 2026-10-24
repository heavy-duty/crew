### Fixed

- `crew hire` refuses an off-roster box whose registry shares any repository with the fleet's production list, naming the shared repository, rather than only a box whose registry equals it (#328).
- A per-box selection that merely narrows production no longer arms a second agent against the repositories it kept, while a disjoint sandbox registry still hires (#328).

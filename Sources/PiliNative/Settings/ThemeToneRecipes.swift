// FlexSeedScheme 5.0.1, BSD-3-Clause; see Notices/FlexSeedScheme.txt.
// Rows contain day and night: chroma/min for three roles, tertiary rotation, primary/container/secondary/tertiary tones, neutral chroma and surface tone.
enum ThemeToneRecipes {
  static let values: [[[Double?]]] = [
    [[36, 36, 16, 0, 24, 0, 60, 40, 90, 40, 40, 6, 98], [36, 36, 16, 0, 24, 0, 60, 80, 30, 80, 80, 6, 6]], // material
    [[48, 48, 16, 0, 24, 0, 60, 40, 90, 40, 40, 4, 99], [48, 48, 16, 0, 24, 0, 60, 80, 30, 80, 80, 4, 10]], // material3Legacy
    [[30, 0, 14, 0, 20, 0, 60, 40, 90, 40, 40, 6, 98], [30, 0, 14, 0, 20, 0, 60, 80, 30, 80, 80, 6, 6]], // soft
    [[nil, 50, nil, 0, nil, 0, 60, 30, 90, 40, 40, 6, 98], [nil, 50, nil, 0, nil, 0, 60, 80, 20, 80, 80, 6, 6]], // vivid
    [[nil, 50, nil, 0, nil, 0, 60, 30, 90, 40, 40, 5, 98], [nil, 50, nil, 0, nil, 0, 60, 80, 20, 80, 80, 5, 6]], // vividSurfaces
    [[nil, 65, nil, 55, nil, 55, 60, 30, 90, 40, 30, 6, 99], [nil, 65, nil, 55, nil, 55, 60, 80, 20, 80, 80, 6, 4]], // highContrast
    [[nil, 60, nil, 70, nil, 65, 60, 20, 90, 40, 30, 3, 100], [nil, 60, nil, 70, nil, 65, 60, 90, 30, 95, 95, 3, 2]], // ultraContrast
    [[nil, 55, nil, 40, 40, 0, 60, 30, 90, 50, 40, 6, 98], [nil, 55, nil, 40, 40, 0, 60, 80, 30, 90, 80, 6, 6]], // jolly
    [[nil, 50, nil, 0, nil, 0, 60, 30, 90, 40, 40, 5, 100], [nil, 50, nil, 0, nil, 0, 60, 80, 20, 80, 80, 5, 5]], // vividBackground
    [[nil, 55, 26, 0, 36, 0, 0, 40, 90, 40, 30, 6, 98], [nil, 55, 26, 0, 36, 0, 0, 80, 30, 80, 90, 6, 6]], // oneHue
    [[nil, 60, nil, 44, nil, 50, 60, 40, 80, 60, 50, 2, 100], [nil, 60, nil, 44, nil, 50, 60, 80, 40, 70, 87, 2, 6]], // candyPop
    [[nil, 0, nil, 0, nil, 0, 60, 40, 80, 50, 50, 2, 99], [nil, 0, nil, 0, nil, 0, 60, 80, 40, 70, 87, 3, 4]], // chroma
  ]
}

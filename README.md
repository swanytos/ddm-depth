# DDM Depth

Petite app iPhone qui envoie en temps réel l'image couleur **et** la profondeur (en mètres) de la caméra avant TrueDepth vers un PC, en TCP sur le réseau local. Récepteur Python : projet DayDreamingMachine (`glove_tracking.sources.iphone_depth`).

- Compilée gratuitement par GitHub Actions (dépôt public, `.github/workflows/build.yml`) : onglet **Actions** > dernier run > artefact **DDMDepth-ipa**.
- Installée depuis Windows avec **Sideloadly** et un identifiant Apple gratuit (à refaire tous les 7 jours).

Format d'un paquet (little-endian) : en-tête de 60 octets (`DDMD`, version, horodatage µs, index, taille couleur, taille profondeur, fx fy cx cy, taille JPEG, taille profondeur) puis JPEG puis profondeur float16.

Inspiré de [Sologala/iphone-truedepth-streaming](https://github.com/Sologala/iphone-truedepth-streaming) (licence MIT).

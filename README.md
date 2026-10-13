# ChatIt

Assistant IA façon ChatGPT (Flutter, package `com.devIt.chatit`) qui se connecte à
[LocalAI](https://github.com/mudler/LocalAI) quand il est démarré.

## Fonctionnalités
- **Chat** en streaming (Markdown, copier, régénérer, stop)
- **Vision** : joindre des images / photos (modèles multimodaux type llava)
- **Génération d'images** (`/v1/images/generations`, Stable Diffusion / Flux)
- **Documents** : PDF, txt, md, csv, code… le texte est injecté dans le prompt
- **Vocal** : dictée (`/v1/audio/transcriptions`, whisper) et lecture des réponses (`/v1/audio/speech`), lecture auto optionnelle
- **Historique** local SQLite : recherche, renommage, suppression, export JSON
- **Détection de LocalAI** : ping `/readyz` puis `/v1/models` toutes les 15 s, indicateur vert/rouge

## Démarrer LocalAI
```bash
docker run -p 8080:8080 --name local-ai -ti localai/localai:latest
```
Puis dans ChatIt › Paramètres, saisir l'URL (ex. `http://192.168.1.10:8080` depuis un téléphone).

## Lancer
```bash
flutter pub get
flutter run
```
Icône régénérable via `dart run flutter_launcher_icons` (sources dans `assets/icon/`).

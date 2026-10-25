## Install

1. Download **Fenestra.zip** below and open it.
2. Drag **Fenestra** into your **Applications** folder.
3. Open Fenestra. macOS says it could not verify the app: click **Done**.
   *Fenestra is not notarized by Apple (that takes a paid developer account), so macOS asks you to confirm it once.*
4. Open **System Settings › Privacy & Security**, scroll down to *“Fenestra” was blocked…*, click
   **Open Anyway** and confirm.
5. Allow **Accessibility** when asked (required), and **Screen Recording** for the window previews.

In the Terminal, steps 3 and 4 can be replaced by:

```bash
xattr -dr com.apple.quarantine /Applications/Fenestra.app
```

macOS 14 Sonoma or later, Apple silicon or Intel. After an update, macOS asks for the permissions again.

## Installation (français)

1. Télécharge **Fenestra.zip** ci-dessous et ouvre-le.
2. Glisse **Fenestra** dans le dossier **Applications**.
3. Ouvre Fenestra. macOS indique qu'il n'a pas pu vérifier l'app : clique sur **Terminé**.
   *Fenestra n'est pas notarisée par Apple (il faut un compte développeur payant) : macOS demande donc une confirmation, une seule fois.*
4. Ouvre **Réglages Système › Confidentialité et sécurité**, descends jusqu'à *« Fenestra » a été bloqué…*,
   clique sur **Ouvrir quand même** et confirme.
5. Autorise **Accessibilité** quand c'est demandé (obligatoire), et **Enregistrement de l'écran** pour les aperçus.

Dans le Terminal, les étapes 3 et 4 se remplacent par :

```bash
xattr -dr com.apple.quarantine /Applications/Fenestra.app
```

macOS 14 Sonoma ou plus récent, Apple Silicon ou Intel. Après une mise à jour, macOS redemande les autorisations.

<p align="center">
  <img src="docs/icon.png" width="128" height="128" alt="Icône de Fenestra">
</p>

<h1 align="center">Fenestra</h1>

<p align="center">
  <b>Un vrai sélecteur de fenêtres pour macOS.</b><br>
  <kbd>⌘</kbd> <kbd>⇥</kbd> affiche toutes les fenêtres, pas seulement les apps, avec aperçus, recherche, onglets Chrome et rangement au clavier.
</p>

<p align="center">
  <img src="docs/switcher.png" width="860" alt="Le sélecteur ⌘⇥ de Fenestra : aperçus des fenêtres de tous les bureaux, apps sans fenêtre en dessous">
</p>

<p align="center"><a href="README.md">🇬🇧 Read in English</a></p>

## Pourquoi

Le <kbd>⌘</kbd><kbd>⇥</kbd> de macOS passe d'une **app** à l'autre. Avec trois fenêtres Chrome, un terminal et
un Slack sur un autre bureau, atteindre la bonne fenêtre demande ⌘⇥, puis ⌘\`, puis de deviner.

Fenestra remplace ⌘⇥ par un sélecteur qui liste **chaque fenêtre**, comme Alt-Tab sous Windows, et ajoute ce
qui manque à macOS autour.

## Fonctionnalités

- **Toutes les fenêtres, avec un aperçu** — de la plus récemment utilisée à la plus ancienne, fenêtres réduites comprises.
- **Tous les bureaux et les apps en plein écran** — étiquetées *Bureau 2* ou *Plein écran* ; en choisir une t'y emmène.
- **Recherche au clavier** — filtre les fenêtres **et les onglets Chrome** par app, titre ou site, sans tenir compte des majuscules ni des accents.
- **Les fenêtres de l'app active** — avec la touche « fenêtre suivante » de macOS : <kbd>⌘</kbd><kbd><</kbd>
  sur un clavier français, <kbd>⌘</kbd><kbd>\`</kbd> sur un clavier US.
- **Rangement des fenêtres** — <kbd>⌃</kbd><kbd>⌥</kbd> + flèches pour les moitiés (encore : ⅓ puis ⅔),
  tiers, plein écran et centrage.
- **Tout masquer** — <kbd>⌥</kbd><kbd>⌘</kbd><kbd>M</kbd> libère l'écran ; un second appui remet tout.
- **Agir sans quitter ⌘⇥** — fermer une fenêtre ou un onglet, réduire, masquer ou quitter une app.
- **Pensé pour macOS 26** — panneau Liquid Glass, compatible Stage Manager, AZERTY comme QWERTY.
- **Ne prend jamais ⌘⇥ en otage** — en pause, quittée (ou plantée), Fenestra rend ses raccourcis à macOS.

<p align="center">
  <img src="docs/search.png" width="620" alt="Recherche « fenestra » : les fenêtres, puis les onglets Chrome correspondants">
</p>

## Installation

### Télécharger

**[⬇︎ Télécharger Fenestra.zip](https://github.com/theopqrs/fenestra/releases/latest/download/Fenestra.zip)** —
macOS 14 Sonoma ou plus récent, Apple Silicon ou Intel.

1. Dézippe-le et glisse **Fenestra** dans **Applications**.
2. Ouvre-la. macOS indique qu'il n'a pas pu vérifier l'app : clique sur **Terminé**.
3. Dans **Réglages Système › Confidentialité et sécurité**, clique sur **Ouvrir quand même** à côté de
   *« Fenestra » a été bloqué…* et confirme.

Fenestra est gratuite et open source, mais pas notarisée par Apple (il faut un compte développeur payant),
d'où cette confirmation unique. Dans le Terminal, les étapes 2 et 3 se remplacent par
`xattr -dr com.apple.quarantine /Applications/Fenestra.app`.

### Compiler soi-même

Prérequis : **macOS 14 Sonoma ou plus récent** (développée sur macOS 26 / 27) et Xcode ou les Command Line
Tools (Swift 5.10+).

```bash
git clone https://github.com/theopqrs/fenestra.git
cd fenestra
./build.sh --install
```

`build.sh` compile, crée `Fenestra.app`, la signe avec ton certificat Apple Development si tu en as un (sinon
en ad hoc), la copie dans `/Applications` et la lance. Sans `--install`, l'app reste dans `build/`.

### Autorisations

Fenestra vit dans la barre des menus (pas d'icône dans le Dock). Au premier lancement, autorise-la dans
**Réglages Système › Confidentialité et sécurité** :

| Autorisation | Sert à | Obligatoire |
| --- | --- | --- |
| **Accessibilité** | intercepter ⌘⇥, lister, activer et déplacer les fenêtres | oui |
| **Enregistrement de l'écran** | les aperçus des fenêtres | non — icônes sinon |
| **Automatisation › Google Chrome** | chercher dans les onglets Chrome | non — fenêtres seulement sinon |

> Signée en ad hoc, l'app perd ses autorisations à chaque recompilation. Une signature avec un vrai
> certificat (le script en choisit un automatiquement) les conserve.

## Raccourcis

### Dans le sélecteur

| Touches | Action |
| --- | --- |
| <kbd>⌘</kbd><kbd>⇥</kbd> / <kbd>⌘</kbd><kbd>⇧</kbd><kbd>⇥</kbd> | ouvrir, fenêtre suivante / précédente |
| <kbd>←</kbd> <kbd>→</kbd> <kbd>↑</kbd> <kbd>↓</kbd> | se déplacer dans la grille |
| relâcher <kbd>⌘</kbd> ou <kbd>↩</kbd> | aller à la fenêtre sélectionnée |
| une lettre | chercher — le panneau reste alors ouvert jusqu'à <kbd>↩</kbd> ou <kbd>esc</kbd> |
| <kbd>⌫</kbd> | effacer un caractère de la recherche |
| <kbd>⌥</kbd><kbd>W</kbd> | fermer la fenêtre, ou l'onglet |
| <kbd>⌥</kbd><kbd>M</kbd> | réduire / restaurer la fenêtre |
| <kbd>⌥</kbd><kbd>H</kbd> | masquer / afficher l'app |
| <kbd>⌥</kbd><kbd>Q</kbd> | quitter l'app |
| <kbd>esc</kbd> | annuler |

Un ⌘⇥ rapide revient directement à la fenêtre précédente sans rien afficher. La souris marche aussi :
survol pour sélectionner, clic pour y aller.

### Partout

| Touches | Action |
| --- | --- |
| <kbd>⌘</kbd><kbd><</kbd> (<kbd>⌘</kbd><kbd>\`</kbd> en QWERTY) | sélecteur limité aux fenêtres de l'app active |
| <kbd>⌥</kbd><kbd>⌘</kbd><kbd>M</kbd> | tout masquer / tout réafficher |
| <kbd>⌃</kbd><kbd>⌥</kbd><kbd>←</kbd> <kbd>→</kbd> | moitié gauche / droite — encore : ⅓, puis ⅔ |
| <kbd>⌃</kbd><kbd>⌥</kbd><kbd>↑</kbd> <kbd>↓</kbd> | moitié haut / bas — encore : ⅓, puis ⅔ |
| <kbd>⌃</kbd><kbd>⌥</kbd><kbd>↩</kbd> | plein écran — encore : taille d'avant |
| <kbd>⌃</kbd><kbd>⌥</kbd><kbd>C</kbd> | centrer |
| <kbd>⌃</kbd><kbd>⌥</kbd><kbd>D</kbd> <kbd>F</kbd> <kbd>G</kbd> | tiers gauche / centre / droite |
| <kbd>⌃</kbd><kbd>⌥</kbd><kbd>⌫</kbd> | taille d'avant le rangement |

Chaque fonction se désactive depuis l'icône de la barre des menus, qui rappelle aussi ces raccourcis.

## Comment ça marche

- **Clavier** — un `CGEventTap` sur son propre thread. Tant que Fenestra tourne, les raccourcis système ⌘⇥ et
  « fenêtre suivante » sont désactivés (`CGSSetSymbolicHotKeyEnabled`), puis rétablis en pause, à la
  fermeture ou en cas de plantage.
- **Fenêtres** — l'API d'accessibilité pour le bureau courant ; SkyLight (`CGSCopyWindowsWithOptionsAndTags`)
  pour les autres bureaux et le plein écran, dont les éléments d'accessibilité sont mis en cache au fil de
  l'eau ou retrouvés par force brute (la technique d'AltTab).
- **Ordre** — les changements de fenêtre active sont suivis par notifications d'accessibilité : l'ordre est
  l'ordre réel d'utilisation, d'un bureau à l'autre.
- **Activation** — `_SLPSSetFrontProcessWithOptions` et des événements de fenêtre clé (comme yabai et AltTab),
  ce qui bascule aussi sur le bon bureau.
- **Aperçus** — `CGSHWCaptureWindowList`. macOS ne dessine pas les fenêtres rangées dans la bande de Stage
  Manager ni celles des bureaux cachés : Fenestra capture donc chaque fenêtre quand elle est visible et garde
  sa dernière image en mémoire et dans `~/Library/Caches`.
- **Onglets Chrome** — AppleScript lancé par `osascript`, qui lit tous les titres et URL en quelques requêtes groupées.

## Limites

- **API privées de macOS.** C'est ce qui rend tout cela possible, mais ça exclut l'App Store et une mise à
  jour de macOS peut casser quelque chose.
- **L'interface est en français** pour l'instant.
- Une fenêtre jamais affichée depuis le lancement de Fenestra montre l'icône de son app au lieu d'un aperçu.
- La recherche d'onglets ne couvre que Google Chrome (les autres navigateurs Chromium seraient faciles à ajouter).
- macOS bloque l'interception du clavier quand un champ de mot de passe est actif : ⌘⇥ n'y fait rien.

## Développement

La structure du code et les modes de débogage (`--list`, `--tabs`, `--tiling-test`, `--demo-screenshot`)
sont décrits dans le [README anglais](README.md#development). Pour publier une version :
`./release.sh 1.1.0` compile une app universelle, la zippe et crée la Release GitHub.

## Remerciements

Fenestra s'appuie sur des techniques documentées par [AltTab](https://github.com/lwouis/alt-tab-macos),
[yabai](https://github.com/koekeishiya/yabai) et [Rectangle](https://github.com/rxhanson/Rectangle).
Merci à leurs auteurs.

## Licence

[MIT](LICENSE) © theopqrs

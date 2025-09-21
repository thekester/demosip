# Demo SIP Show

Ce dépôt contient `demo_sip_show.sh`, un script Bash qui orchestre une démonstration SIP/Asterisk complète dans un environnement LXD. Il prépare automatiquement une instance Asterisk, configure des comptes SIP, ouvre des terminaux d'observation et pilote des clients PJSUA pour illustrer un scénario de centre d'appels (mode guidé puis mode "hacker").

## Fonctionnalités clés

- **Préparation automatique du PBX** : sauvegarde des fichiers `sip.conf`/`extensions.conf`, création de dialplan temporel, génération des extensions et rechargement d'Asterisk.
- **Gestion audio immersive** : conversion automatique de sons (`.mp3` -> `.wav`), affectation de rôles (sonnerie, connexion, raccrochage) et mise en scène synchronisée côté conteneur et côté hôte.
- **Dashboard temps réel** : affiche l'état du scénario, les appels actifs (`core show channels`), les pairs SIP, et décrit chaque étape (origine, destination, sons utilisés, durée prévue).
- **Scénario piloté + mode rafale** : le script exécute un scénario déterministe (service horaire, appels croisés) puis des rafales configurables pour simuler des attaques ou du stress trafic.
- **Nettoyage intelligent** : arrêt des sessions PJSUA/Asterisk existantes, purge des fichiers de boucle, préparation des logs et fenêtres terminal.

## Prérequis

- Hôte Linux avec **LXD/LXC** et des conteneurs nommés (`asterisk01`, `ua01`, `ua02` par défaut).
- Clients **PJSUA** installés dans les conteneurs UA.
- `ffmpeg`, `aplay`, `gnome-terminal` ou `xterm` disponibles sur l'hôte.
- Accès aux sons (`sound/*.wav`) qui accompagnent la démo.

## Variables utiles

Toutes les variables possèdent des valeurs par défaut mais peuvent être redéfinies à l'exécution :

- `AST_CT`, `UAS`, `UA_PORTS`, `AST_EXT_BASE`, `AST_SVC_TIME`
- `SOUND_DIR`, `RING_SOUND`, `CONNECT_SOUND`, `HANG_SOUND`
- `SOUND_MIN_CALL_DURATION`, `SOUND_GUIDE_PAUSE`, `SOUND_BURST_PAUSE`, `SOUND_PLAYBACK_DELAY`, `SOUND_HANG_DELAY`
- `HACKER_MODE`, `LOOP_COUNT`, `CALL_BURST`, `BURST_INTERVAL_MS`

## Utilisation

```bash
./demo_sip_show.sh
```

Le script :
1. Vérifie la présence de lxc/pjsua et des terminaux graphiques.
2. Nettoie l'environnement précédent.
3. Prépare le PBX Asterisk et les fichiers audio.
4. Ouvre les terminaux (dashboard, logs, peers, Asterisk, UAs).
5. Exécute le scénario guidé puis, si activé, les rafales.

## Personnalisation des sons

Déposez vos fichiers `.mp3` dans `sound/` ; le script les convertit en `.wav` et les répartit entre les rôles. Vous pouvez aussi fournir directement vos WAV via les variables d'environnement.

## Journalisation

Tous les appels PJSUA sont journalisés dans `~/sip-tests` (modifiable via `LOG_DIR`). Le dashboard suit l'état courant dans `~/.sipdemo_current_step` et les rafales dans `~/.sipdemo_loop_state`.

## Dépannage rapide

- **"variable sans liaison"** : exécutez le script depuis Bash (le shebang relance en Bash si nécessaire) et vérifiez les sons/variables.
- **Pas de son** : assurez-vous que `aplay` est installé et que les WAV sont lisibles.
- **Fichiers Asterisk non modifiés** : vérifier que le conteneur `AST_CT` existe et que les permissions permettent la copie/push des fichiers.

Bonnes démos !

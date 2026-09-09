# Une machine d'usine sous NixOS, sur Incus

La procédure vérifiée de bout en bout le 2026-09-09, sur un hôte TrueNAS SCALE
25.10 qui fait tourner Incus. Ce qui suit n'est pas une intention : chaque
commande a été passée, et la section « Vérification » dit ce qu'on a constaté.

Elle remplace, pour une machine déclarative, la voie impérative (image Ubuntu
`/cloud` + `cloud-init` + `install.sh`) qui reste documentée chez les
consommateurs.

## L'idée

nixpkgs sait produire une image de VM Incus. Le module
`virtualisation/incus-virtual-machine.nix` donne deux sorties :

- `system.build.qemuImage` — un disque `qcow2`, partitionné EFI, systemd-boot ;
- `system.build.metadata` — le tarball `metadata.yaml` qu'Incus attend.

On les construit sur le poste, on les copie sur l'hôte, on importe, on crée
l'instance. Aucune installation à distance, aucun `nixos-anywhere` : la machine
naît déjà configurée.

## La recette

### 1. Construire

```bash
nix build .#nixosConfigurations.<hôte>.config.system.build.qemuImage -o result-img
nix build .#nixosConfigurations.<hôte>.config.system.build.metadata  -o result-meta
```

**Épinglez la RÉVISION, pas la branche.** `nixos-26.05` bouge : une image
construite sur la branche ne porte pas forcément la même toolchain que le reste
de votre parc, et un test qui passerait sur une autre toolchain que celle qu'on
déploie ne prouve rien. Reprenez le `rev` du `flake.lock` qui gouverne vos
machines.

### 2. Copier

```bash
scp result-img/nixos.qcow2 result-meta/tarball/*.tar.xz <hôte>:/chemin/sur/un/pool
```

⚠️ **Pas dans `/tmp` sur TrueNAS** : c'est un `tmpfs`, donc de la RAM. Une image
de 600 Mo y est 600 Mo de mémoire prise à l'hyperviseur, au moment précis où on
s'apprête à démarrer une VM.

### 3. Importer

```bash
incus image import <metadata>.tar.xz nixos.qcow2 --alias <hôte>
incus image list          # doit afficher TYPE = VIRTUAL-MACHINE
```

**Vérifiez ce `TYPE`, c'est le point qui décide de tout.** Le `metadata.yaml` que
produit nixpkgs ne porte **aucun champ de type** — il ne contient que
`architecture`, `creation_date`, `properties`, `templates` — et le tarball
s'appelle `…-lxc-metadata-…`, ce qui laisse craindre une image de conteneur.
C'est Incus qui tranche, sur la nature du second fichier : un `qcow2` fait une
image de machine virtuelle. Constaté :

```
ARCHITECTURE  FINGERPRINT   TYPE             DESCRIPTION
x86_64        0f02262ce44f  VIRTUAL-MACHINE  NixOS Yarara 26.05.…
```

### 4. Créer l'instance

```bash
incus init <hôte> <hôte> --vm -s <pool> \
  -c limits.cpu=6 -c limits.memory=24GiB -d root,size=200GiB

# LE RÉSEAU, et ce n'est pas le défaut — voir le piège plus bas.
incus config device add <hôte> eth0 nic nictype=macvlan parent=<nic de l'hôte>

# LE VOLUME D'ÉTAT, en BLOC : il porte les identifiants, les caches d'images et
# les artefacts, et il doit survivre à une remise à zéro.
incus storage volume create <pool> <hôte>-state --type=block size=100GiB
incus config device add <hôte> state disk pool=<pool> source=<hôte>-state

# LE SECURE BOOT, sans quoi la machine ne démarre pas — voir le piège plus bas.
incus config set <hôte> security.secureboot=false

incus start <hôte>
```

## Les deux pièges

### Secure Boot refuse le disque, et ça ressemble à un disque absent

**Incus active Secure Boot par défaut sur les VM.** Le `systemd-boot` que produit
nixpkgs n'est signé par personne, donc le firmware le refuse. Ubuntu et Debian ne
rencontrent jamais ça : ils embarquent un shim signé par Microsoft.

Le symptôme trompe. La machine part en PXE, échoue, et on lit « rien à
démarrer » — la conclusion naturelle étant que l'image est mauvaise ou que le
disque n'est pas attaché. La ligne qui détrompe est la **première** de la
console, avant tout le bruit réseau :

```
BdsDxe: loading Boot0001 "UEFI QEMU QEMU HARDDISK " from …Scsi(0x0,0x1)
BdsDxe: failed to load Boot0001 "UEFI QEMU QEMU HARDDISK " …: Access Denied
```

`Access Denied`, pas `Not Found` : **le disque est trouvé, il est refusé.** Les
`Not Found` qui suivent ne concernent que les entrées PXE, essayées ensuite.

```bash
incus config set <hôte> security.secureboot=false
```

Lisez toujours le **début** de `incus console <hôte> --show-log`, jamais la fin :
la fin ne montre que le repli réseau, qui n'est pas la panne.

### Le profil par défaut branche sur le NAT, pas sur le LAN

Le profil `default` d'Incus attache `eth0` au bridge `incusbr0`, qui est du NAT.
Une machine créée sans device explicite obtient une adresse en `10.x`,
joignable depuis l'hôte et de nulle part ailleurs.

Une usine doit être joignable **depuis le poste** — c'est par là que passent
`push-env`, `deploy` et `status`. D'où le device `macvlan` sur la carte physique,
qui lui donne une adresse du LAN et un bail DHCP comme n'importe quelle machine.

Deux conséquences à connaître :

- **Réservez l'adresse sur le routeur**, liée au MAC (`incus config get <hôte>
  volatile.eth0.hwaddr`). Une adresse qui bouge casse tout ce qui la code en dur,
  et fait échouer le `magicRollback` de deploy-rs sur un déploiement pourtant bon.
- **En macvlan, l'hôte ne joint pas ses propres invités.** C'est une propriété du
  mode, pas une erreur. Passez par `incus exec` ou par une autre machine du LAN.

## Vérification

Ce qu'on a constaté, dans cet ordre. On s'arrête au premier échec.

| Ce qu'on regarde | Ce qu'on a obtenu |
|---|---|
| `incus image list` | `TYPE = VIRTUAL-MACHINE` |
| `incus list` | `RUNNING`, et une IPv4 **du LAN** |
| `ssh root@<ip>` **depuis le poste** | répond |
| `nixos-version` | la révision épinglée, à l'identique |
| `lsblk` | le disque racine ET le volume d'état |
| `systemctl is-active incus-agent` | `active` — c'est lui qui remonte l'IP à `incus list` |

L'agent mérite une ligne : sans lui, `incus list` n'affiche aucune adresse, et
l'absence d'adresse ressemble à une machine sans réseau alors qu'elle en a une.
Le module l'active par défaut ; si vous partez d'un autre module, vérifiez-le.

## Ce que cette page ne couvre pas

- **Le montage du volume d'état.** `lsblk` le montre, personne ne le monte : il
  faut une entrée `fileSystems` dans la configuration de l'hôte, et les
  bind-mounts qui en dépendent doivent l'ordonner. C'est le travail du module
  `services.factory`, pas celui de l'hyperviseur.
- **Les mises à jour.** Une fois la machine née, elle se met à jour comme
  n'importe quel hôte NixOS — `deploy-rs`, avec son `magicRollback`. On ne
  réimporte pas une image à chaque changement.
- **Les secrets.** Voir [`configuration.md`](configuration.md) et le README.

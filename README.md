# Log in to a machine that has no open ports

Remote access normally needs an open port: a door on the machine that
attackers can find and knock on. NoPorts needs no door.

This demo shows it on your own computer:

1. It starts a stand-in machine: a Docker container that behaves like a
   separate computer.
2. It logs in to that machine.
3. While logged in, it scans all 65,535 of the machine's ports. The scan
   finds nothing open.

NoPorts is built to do the same for a real server or device.

## Try it

You need [Docker](https://www.docker.com/get-started/). Then:

```
git clone https://github.com/atsign-foundation/noports-demo
cd noports-demo
./demo.sh web
```

This opens the demo in your browser. You click through it step by step,
watch a diagram of the connection being made, and press buttons to look
inside the machines yourself.

On Windows, run these commands inside
[WSL 2](docs/DETAILS.md#running-on-windows), not PowerShell.

The first run takes 1–3 minutes. Nothing leaves your computer, and you need
no accounts and no sign-up.

- Something broke? Run `./doctor.sh`.
- Finished? Run `./teardown.sh` to remove everything.

## Prefer the terminal?

```
./demo.sh --step
```

This runs the same demo as text in your terminal. It pauses after each step;
press Enter to move on.

## Nothing to install?

[![Open in GitHub Codespaces](https://github.com/codespaces/badge.svg)](https://codespaces.new/atsign-foundation/noports-demo)

This runs the web page version on a GitHub machine, in your browser. You need
a GitHub account. The first start takes a few minutes.

## Want more?

- [Slide deck](docs/noports-demo-explained.pptx): how it works, in pictures.
- [Full details](docs/DETAILS.md): how it works, what the demo does not prove,
  versions and troubleshooting.

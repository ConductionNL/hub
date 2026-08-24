#!/usr/bin/env python3
# SPDX-License-Identifier: EUPL-1.2
# role: entrypoint
#
# scripts/onboard_gui.py — grafische voorkant voor scripts/onboard.sh.
#
# Dit is bewust een dun laagje. Alle logica zit in onboard.sh; deze GUI vult
# velden voor, stelt het commando samen en laat de uitvoer zien. Er is geen
# tweede implementatie van de onboarding, want twee implementaties gaan
# uiteenlopen en dan is onduidelijk welke de waarheid is.
#
# Waarom hij bestaat: de eerste stap van een nieuwe beheerder is uitzoeken hoe
# een bestand moet heten dat hij nog niet heeft. Een veld met de naam erin, dat
# meteen het volledige pad toont en of het er staat, scheelt die zoektocht.
#
# De naamconventie staat hier NIET in. Die wordt opgevraagd met
# `onboard.sh --print-emk-path <naam>`, zodat het patroon op één plek leeft.
#
# Writes: niets zelf — alles gaat via onboard.sh, en die wijzigt pas met --apply
# Idempotent: ja (de GUI heeft geen eigen staat)
# Requires: python3 met tkinter (op RHEL-achtigen: `sudo dnf install python3-tkinter`)
#
# Usage:
#   ./scripts/onboard_gui.py
#   ./scripts/onboard_gui.py --name thijn        # veld voorgevuld
#   python3 scripts/onboard_gui.py               # idem
#
# Zonder tkinter meldt dit script dat en verwijst naar onboard.sh; de
# onboarding hoort niet te stranden op een ontbrekend GUI-pakket.

from __future__ import annotations

import argparse
import os
import queue
import shlex
import subprocess
import sys
import threading
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
ONBOARD = SCRIPT_DIR / "onboard.sh"

# Defaults staan hier alleen als voorvulling van de velden. onboard.sh heeft
# zijn eigen defaults; wat hier staat moet daarmee overeenkomen, en de test
# onderaan controleert dat ze niet uiteenlopen.
DEFAULTS = {
    "namespace": "garden-wh2mnkj",
    "shoots": "test-accept conductionprod con-prod",
    "default_shoot": "con-prod",
}


WORK_DOMAIN = "conduction.nl"


def guess_name() -> str:
    """Voornaam voorvullen — alleen als de bron betrouwbaar is.

    De conventie gebruikt de **voornaam** (`mark`, `robert`, `ruben`). Een
    zakelijk mailadres levert die: `thijn@conduction.nl` → `thijn`. Een
    privéadres niet: het git-mailadres op de machine waar dit gebouwd is was
    `mwesterweel@hotmail.com`, wat `mwesterweel` zou opleveren terwijl het
    bestand `mark` heet. Een GitHub-accountnaam werkt evenmin.

    Daarom vullen we alleen voor bij een `@conduction.nl`-adres. Anders blijft
    het veld leeg: een leeg veld met een duidelijke hint is beter dan een
    zelfverzekerd verkeerde naam, want die leidt tot een aanvraag bij Fuga voor
    een bestand dat niemand kan gebruiken.
    """
    try:
        out = subprocess.run(
            ["git", "config", "--get", "user.email"],
            capture_output=True, text=True, timeout=5, check=False,
        ).stdout.strip().lower()
    except (OSError, subprocess.SubprocessError):
        return ""
    if out.endswith("@" + WORK_DOMAIN):
        return out.split("@", 1)[0].split(".", 1)[0]
    return ""


def emk_path_for(name: str) -> str:
    """Vraag onboard.sh om het verwachte pad. Geen tweede implementatie."""
    if not name.strip():
        return ""
    try:
        res = subprocess.run(
            [str(ONBOARD), "--print-emk-path", name],
            capture_output=True, text=True, timeout=10, check=False,
        )
    except (OSError, subprocess.SubprocessError):
        return ""
    return res.stdout.strip() if res.returncode == 0 else ""


class OnboardGui:
    def __init__(self, root, initial_name: str) -> None:
        import tkinter as tk
        from tkinter import ttk

        self.tk = tk
        self.root = root
        self.output_queue: queue.Queue[str | None] = queue.Queue()
        self.running = False

        root.title("Conduction — werkplek inrichten")
        root.minsize(760, 560)

        frame = ttk.Frame(root, padding=12)
        frame.grid(sticky="nsew")
        root.columnconfigure(0, weight=1)
        root.rowconfigure(0, weight=1)
        frame.columnconfigure(1, weight=1)

        row = 0
        ttk.Label(
            frame,
            text="Vul je naam in. De rest is voorgevuld en hoef je alleen aan te "
                 "raken als iets afwijkt.",
            wraplength=700,
        ).grid(row=row, column=0, columnspan=3, sticky="w", pady=(0, 10))

        row += 1
        self.name = self._field(
            frame, row, "Voornaam of mailadres", initial_name,
            "je vóórnaam, zoals in de bestandsnaam — bijv. thijn")
        self.name.bind("<KeyRelease>", lambda _e: self.refresh_emk())

        row += 1
        ttk.Label(frame, text="Verwacht bestand").grid(row=row, column=0, sticky="w", pady=3)
        self.emk_label = ttk.Label(frame, text="", foreground="#666", wraplength=520,
                                   justify="left")
        self.emk_label.grid(row=row, column=1, columnspan=2, sticky="w", pady=3)

        row += 1
        self.root_dir = self._field(
            frame, row, "Fleet-map",
            str(SCRIPT_DIR.parent.parent), "waar de zusterrepos komen")

        row += 1
        self.namespace = self._field(frame, row, "Gardener-namespace",
                                     DEFAULTS["namespace"], "garden-<project>")

        row += 1
        self.shoots = self._field(frame, row, "Clusters",
                                  DEFAULTS["shoots"], "ruimte-gescheiden")

        row += 1
        self.default_shoot = self._field(
            frame, row, "Naar ~/.kube/config",
            DEFAULTS["default_shoot"], "welk cluster de kale kubectl gebruikt")

        row += 1
        self.write_profile = tk.BooleanVar(value=True)
        ttk.Checkbutton(
            frame,
            text="Env-vars in het shellprofiel zetten (CONDUCTION_HUB, CLAUDE_GUARDRAIL_CONFIG)",
            variable=self.write_profile,
        ).grid(row=row, column=0, columnspan=3, sticky="w", pady=(8, 2))

        row += 1
        buttons = ttk.Frame(frame)
        buttons.grid(row=row, column=0, columnspan=3, sticky="w", pady=10)
        self.check_button = ttk.Button(buttons, text="Controleren (wijzigt niets)",
                                       command=self.run_check)
        self.check_button.grid(row=0, column=0, padx=(0, 8))
        self.apply_button = ttk.Button(buttons, text="Uitvoeren", command=self.run_apply)
        self.apply_button.grid(row=0, column=1)

        row += 1
        ttk.Label(frame, text="Uitvoer").grid(row=row, column=0, sticky="w")

        row += 1
        self.output = tk.Text(frame, height=18, wrap="none",
                              font=("monospace", 10), background="#111",
                              foreground="#ddd", insertbackground="#ddd")
        self.output.grid(row=row, column=0, columnspan=3, sticky="nsew", pady=(2, 0))
        frame.rowconfigure(row, weight=1)
        scroll = ttk.Scrollbar(frame, orient="vertical", command=self.output.yview)
        scroll.grid(row=row, column=3, sticky="ns")
        self.output["yscrollcommand"] = scroll.set

        self.refresh_emk()
        self.root.after(100, self.drain_output)

    def _field(self, frame, row: int, label: str, value: str, hint: str):
        from tkinter import ttk

        ttk.Label(frame, text=label).grid(row=row, column=0, sticky="w", pady=3)
        entry = ttk.Entry(frame)
        entry.insert(0, value)
        entry.grid(row=row, column=1, sticky="ew", pady=3, padx=(6, 6))
        ttk.Label(frame, text=hint, foreground="#888").grid(row=row, column=2, sticky="w")
        return entry

    # --- EMK-pad ----------------------------------------------------------

    def refresh_emk(self) -> None:
        """Toon het verwachte pad en of het er staat.

        Dit is het enige veld dat live meebeweegt, want het is het enige dat de
        gebruiker niet kan weten: hoe het bestand moet heten dat hij nog moet
        aanvragen.
        """
        path = emk_path_for(self.name.get())
        if not path:
            self.emk_label.configure(text="(vul een naam in)", foreground="#888")
            return
        if Path(path).is_file():
            self.emk_label.configure(text=f"{path}\nstaat er ✓", foreground="#1a7f37")
        else:
            self.emk_label.configure(
                text=f"{path}\nontbreekt — vraag dit bestand aan bij Fuga Cloud en "
                     f"zet het op precies dit pad",
                foreground="#b35900")

    # --- uitvoeren --------------------------------------------------------

    def build_command(self, apply_changes: bool) -> list[str]:
        cmd = [str(ONBOARD), "--emk-name", self.name.get().strip()]
        if apply_changes:
            cmd.append("--apply")
            if self.write_profile.get():
                cmd.append("--write-profile")
        return cmd

    def build_env(self) -> dict[str, str]:
        env = dict(os.environ)
        env["ROOT"] = self.root_dir.get().strip()
        env["GARDENER_NAMESPACE"] = self.namespace.get().strip()
        env["SHOOTS"] = self.shoots.get().strip()
        env["DEFAULT_SHOOT"] = self.default_shoot.get().strip()
        return env

    def run_check(self) -> None:
        self.launch(self.build_command(False), self.build_env())

    def run_apply(self) -> None:
        from tkinter import messagebox

        if not messagebox.askokcancel(
            "Uitvoeren",
            "Dit wijzigt je werkplek:\n\n"
            "• repos klonen naast de fleet-map\n"
            "• plugins installeren\n"
            "• deny-regels in ~/.claude/settings.json\n"
            "• kubeconfigs schrijven en ~/.kube/config vervangen\n"
            "  (de oude wordt geback-upt als config.bak)\n\n"
            "Doorgaan?",
        ):
            return
        self.launch(self.build_command(True), self.build_env())

    def launch(self, cmd: list[str], env: dict[str, str]) -> None:
        if self.running:
            return
        self.running = True
        self.check_button.state(["disabled"])
        self.apply_button.state(["disabled"])
        self.output.delete("1.0", "end")
        self.append(f"$ {shlex.join(cmd)}\n\n")

        def worker() -> None:
            try:
                proc = subprocess.Popen(
                    cmd, env=env, stdout=subprocess.PIPE,
                    stderr=subprocess.STDOUT, text=True, bufsize=1,
                )
                assert proc.stdout is not None
                for line in proc.stdout:
                    self.output_queue.put(line)
                proc.wait()
                self.output_queue.put(f"\n[exitcode {proc.returncode}]\n")
            except (OSError, subprocess.SubprocessError) as exc:
                self.output_queue.put(f"\nkon het script niet starten: {exc}\n")
            finally:
                self.output_queue.put(None)

        threading.Thread(target=worker, daemon=True).start()

    def drain_output(self) -> None:
        """Leeg de wachtrij in de UI-thread; tkinter is niet thread-safe."""
        try:
            while True:
                item = self.output_queue.get_nowait()
                if item is None:
                    self.running = False
                    self.check_button.state(["!disabled"])
                    self.apply_button.state(["!disabled"])
                    self.refresh_emk()
                else:
                    self.append(item)
        except queue.Empty:
            pass
        self.root.after(100, self.drain_output)

    def append(self, text: str) -> None:
        self.output.insert("end", text)
        self.output.see("end")


def main() -> int:
    parser = argparse.ArgumentParser(description="Grafische onboarding voor het Conduction-platform.")
    parser.add_argument("--name", default="", help="voornaam of mailadres, voorvulling van het veld")
    parser.add_argument("--self-test", action="store_true",
                        help="controleer de defaults tegen onboard.sh, zonder GUI")
    args = parser.parse_args()

    if not ONBOARD.is_file():
        print(f"fout: {ONBOARD} niet gevonden", file=sys.stderr)
        return 2

    if args.self_test:
        return self_test()

    try:
        import tkinter as tk
    except ImportError:
        print(
            "tkinter ontbreekt, dus de grafische versie kan niet starten.\n"
            "Installeren: sudo dnf install python3-tkinter  (of python3-tk op Debian).\n"
            "\nDe onboarding werkt ook zonder GUI:\n"
            f"  {ONBOARD} --emk-name <voornaam>            # rapporteren\n"
            f"  {ONBOARD} --emk-name <voornaam> --apply    # uitvoeren",
            file=sys.stderr,
        )
        return 2

    root = tk.Tk()
    OnboardGui(root, args.name or guess_name())
    root.mainloop()
    return 0


def self_test() -> int:
    """Toets wat zonder beeldscherm te toetsen is.

    Het echte risico van deze GUI is niet de weergave maar drift: als de
    voorgevulde waarden hier uiteenlopen met de defaults van onboard.sh, krijgt
    de gebruiker stil een andere configuratie dan het script zou kiezen.
    """
    failures = 0
    script = ONBOARD.read_text(encoding="utf-8")

    for key, value in DEFAULTS.items():
        if f'"{value}"' not in script and f"'{value}'" not in script and value not in script:
            print(f"  FAIL default '{key}' ({value}) staat niet in onboard.sh", file=sys.stderr)
            failures += 1

    # De naamconventie moet uit het script komen, niet uit deze code.
    got = emk_path_for("thijn@conduction.nl")
    if not got.endswith("emk-sa-wh2mnkj_thijn-conduction.yml"):
        print(f"  FAIL --print-emk-path gaf '{got}'", file=sys.stderr)
        failures += 1
    if emk_path_for("  ") != "":
        print("  FAIL lege naam hoort niets te geven", file=sys.stderr)
        failures += 1

    # Het commando mag zonder --apply nooit een muterende vlag dragen.
    class Stub:
        def __init__(self, v): self.v = v
        def get(self): return self.v
    gui = OnboardGui.__new__(OnboardGui)
    gui.name = Stub("thijn")
    gui.write_profile = Stub(True)
    if "--apply" in gui.build_command(False):
        print("  FAIL controleren zet --apply", file=sys.stderr)
        failures += 1
    if "--write-profile" not in gui.build_command(True):
        print("  FAIL uitvoeren zet --write-profile niet", file=sys.stderr)
        failures += 1

    total = len(DEFAULTS) + 4
    print(f"zelftest: {total - failures} geslaagd, {failures} gefaald")
    return 0 if failures == 0 else 1


if __name__ == "__main__":
    sys.exit(main())

"""Download the raw FIFA 22 complete player dataset CSV."""
import os
import requests

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
URL = "https://raw.githubusercontent.com/abineshta/FIFA-22-complete-player-dataset-EDA/main/players_22.csv"
OUT = os.path.join(HERE, "data", "raw", "players_22.csv")


def main():
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    print(f"Downloading {URL}")
    r = requests.get(URL, timeout=120)
    r.raise_for_status()
    with open(OUT, "wb") as f:
        f.write(r.content)
    print(f"Saved {len(r.content):,} bytes to {OUT}")


if __name__ == "__main__":
    main()

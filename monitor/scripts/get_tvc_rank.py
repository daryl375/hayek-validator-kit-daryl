#!/usr/bin/env /root/venv/bin/python

from flask import Flask, jsonify
from threading import Thread
from playwright.sync_api import sync_playwright
import os
import re
import time

app = Flask(__name__)
TVC_RANK = {"output": "Not loaded yet"}

VOTE_ACCOUNT = os.environ["HAYEK_MAINNET_VOTE_ACCOUNT"]

def fetch_tvc_rank_loop():
    global TVC_RANK
    while True:
        try:
            with sync_playwright() as p:
                browser = p.chromium.launch(headless=True)
                page = browser.new_page()
                page.goto(f"https://app.jpool.one/validators/{VOTE_ACCOUNT}")
                page.wait_for_function("""
                    () => Array.from(document.querySelectorAll('.validator-stats__item'))
                              .some(el => el.innerText.includes('TVC Rank'))
                """, timeout=15000)

                tvc_rank = "Not found"
                items = page.locator(".validator-stats__item")
                for i in range(items.count()):
                    text = items.nth(i).text_content(timeout=5000)
                    match = re.search(r'TVC Rank\s+(\d+)', text or "")
                    if match:
                        tvc_rank = match.group(1)
                        break

                TVC_RANK = {"output": f"TVC Rank: {tvc_rank}"}
                browser.close()
        except Exception as e:
            TVC_RANK = {"error": str(e)}

        time.sleep(300)

@app.route('/tvc-rank', methods=['GET'])
def get_tvc_rank():
    return jsonify(TVC_RANK)

def run_flask_app():
    app.run(host='0.0.0.0', port=8000)

if __name__ == '__main__':
    fetch_thread = Thread(target=fetch_tvc_rank_loop)
    fetch_thread.daemon = True
    fetch_thread.start()
    run_flask_app()

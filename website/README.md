# shopaisle.app

The public website: home, Privacy Policy, Terms of Service and Support.

- `build.py` writes the site to `public/`. The legal pages and support answers come from
  `backend/app/legal.py`, so the site, the server and the app always say the same thing.
- `site.css` and `demo.js` are copied to `public/assets/`. Item pictures come from the app's
  ItemIcons, the logo from AisleLogo.
- Preview: `python3 website/build.py && python3 -m http.server -d website/public 8000`
- Publishing: Vercel builds and deploys on every push to `main`, using `vercel.json` at the repo
  root (`python3 website/build.py`, output `website/public`). The domain is set in the Vercel
  project; DNS stays at GoDaddy.

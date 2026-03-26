Optionally register for a WebAIM WAVE API key and paste it in `.env` before starting the audit.
[https://wave.webaim.org/api/register](https://wave.webaim.org/api/register)

```bash
chmod +x a11y-audit.sh

./a11y-audit.sh -f urls.txt --install-deps   # auto-installs missing npm packages
```

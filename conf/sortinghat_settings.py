from sortinghat.config.settings import *  # noqa: F401, F403

# SPA built with BASE_URL="/identities/" — route the API there too
ROOT_URLCONF = 'sh_custom_urls'
STATIC_URL = '/identities/'

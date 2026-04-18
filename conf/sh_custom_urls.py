from django.urls import path, re_path, include
from django.views.generic import TemplateView
from django.views.decorators.csrf import csrf_exempt
from sortinghat.core.views import SortingHatGraphQLView, change_password, api_login
from sortinghat.app.schema import schema

urlpatterns = [
    path('identities/api/', csrf_exempt(SortingHatGraphQLView.as_view(graphiql=False, schema=schema))),
    path('identities/api/login/', api_login, name='api_login'),
    path('identities/password_change/', change_password, name='password_change'),
    re_path(r'^(?!static).*$', TemplateView.as_view(template_name="index.html")),
]

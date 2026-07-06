FROM nginxinc/nginx-unprivileged:1.27-alpine

USER root
RUN rm /etc/nginx/conf.d/default.conf
COPY nginx.conf /etc/nginx/conf.d/default.conf
COPY site /usr/share/nginx/html
RUN chown -R nginx:nginx /usr/share/nginx/html /var/cache/nginx /var/run

USER nginx
EXPOSE 8080
CMD ["nginx", "-g", "daemon off;"]

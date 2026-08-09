FROM scratch

COPY --chown=65532:65532 .platform/reference/server /server
USER 65532:65532
EXPOSE 8080
ENTRYPOINT ["/server"]

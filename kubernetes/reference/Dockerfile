FROM scratch

COPY --chown=65532:65532 server /server
USER 65532:65532
EXPOSE 8080
ENTRYPOINT ["/server"]

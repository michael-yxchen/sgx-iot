##############################################################################
#                                                                            #
#                            Demo base                                       #
#                                                                            #
##############################################################################
FROM initc3/linux-sgx:2.13.3-ubuntu20.04 AS demo-base
#FROM ubuntu:20.04

ENV PYTHONUNBUFFERED 1

RUN apt-get update && apt-get install -y \
                python3.9 \
                python3.9-dev \
                python3-pip \
                vim \
                git \
        && rm -rf /var/lib/apt/lists/*

# symlink python3.9 to python
RUN cd /usr/bin \
    && ln -s pydoc3.9 pydoc \
    && ln -s python3.9 python \
    && ln -s python3.9-config python-config

# pip
# taken from:
# https://github.com/docker-library/python/blob/4bff010c9735707699dd72524c7d1a827f6f5933/3.10-rc/buster/Dockerfile#L71-L95
ENV PYTHON_PIP_VERSION 21.0.1
ENV PYTHON_GET_PIP_URL https://github.com/pypa/get-pip/raw/29f37dbe6b3842ccd52d61816a3044173962ebeb/public/get-pip.py
ENV PYTHON_GET_PIP_SHA256 e03eb8a33d3b441ff484c56a436ff10680479d4bd14e59268e67977ed40904de

RUN set -ex; \
	\
    apt-get update; \
	wget -O get-pip.py "$PYTHON_GET_PIP_URL"; \
	echo "$PYTHON_GET_PIP_SHA256 *get-pip.py" | sha256sum --check --strict -; \
	\
	python get-pip.py \
		--disable-pip-version-check \
		--no-cache-dir \
		"pip==$PYTHON_PIP_VERSION" \
	; \
	pip --version; \
	\
	find /usr/local -depth \
		\( \
			\( -type d -a \( -name test -o -name tests -o -name idle_test \) \) \
			-o \
			\( -type f -a \( -name '*.pyc' -o -name '*.pyo' \) \) \
		\) -exec rm -rf '{}' +; \
	rm -f get-pip.py

# docker cli
RUN set -ex; \
    \
    apt-get update; \
    apt-get install -y \
        apt-transport-https \
        ca-certificates \
        curl \
        gnupg \
        lsb-release;
RUN curl -fsSL https://download.docker.com/linux/ubuntu/gpg | \
        gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg

RUN echo \
    "deb [arch=amd64 signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu \
  $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null

RUN apt-get update && apt-get install -y docker-ce-cli
RUN pip install cryptography ipython requests pyyaml ipdb blessings colorama
RUN set -ex; \
    \
    cd /tmp; \
    git clone --recurse-submodules https://github.com/sbellem/auditee.git; \
    pip install auditee/

##############################################################################
#                                                                            #
#                            Build enclave (trusted)                         #
#                                                                            #
##############################################################################
FROM  nixpkgs/nix AS build-enclave

WORKDIR /usr/src

COPY common /usr/src/common
COPY enclave /usr/src/enclave
COPY interface /usr/src/interface
COPY makefile /usr/src/makefile

COPY nix /usr/src/nix
COPY enclave.nix /usr/src/enclave.nix

# install cachix, to fetch prebuilt sgxsdk from cache
RUN nix-env -iA cachix -f https://cachix.org/api/v1/install
RUN /nix/store/*cachix*/bin/cachix use gluonixpkgs

RUN nix-build enclave.nix

##############################################################################
#                                                                            #
#                            Build app (untrusted)                           #
#                                                                            #
##############################################################################
FROM initc3/linux-sgx:2.13.3-ubuntu20.04 AS build-app

RUN apt-get update && apt-get install -y \
                autotools-dev \
                automake \
                xxd \
                iputils-ping \
                libssl-dev \
                vim \
                git \
        && rm -rf /var/lib/apt/lists/*

WORKDIR /usr/src/sgxiot

ENV SGX_SDK /opt/sgxsdk
ENV PATH $PATH:$SGX_SDK/bin:$SGX_SDK/bin/x64
ENV PKG_CONFIG_PATH $SGX_SDK/pkgconfig
ENV LD_LIBRARY_PATH $SGX_SDK/sdk_libs

COPY . .

ARG SGX_MODE=HW
ENV SGX_MODE $SGX_MODE

ARG SGX_DEBUG=1
ENV SGX_DEBUG $SGX_DEBUG

RUN make just-app

##############################################################################
#                                                                            #
#                            Demo runtime                                    #
#                                                                            #
##############################################################################
FROM demo-base

WORKDIR /usr/src/sgxiot

COPY common /usr/src/sgxiot/common
COPY enclave /usr/src/sgxiot/enclave
COPY interface /usr/src/sgxiot/interface
COPY makefile /usr/src/sgxiot/makefile
COPY nix /usr/src/sgxiot/nix
COPY enclave.nix /usr/src/sgxiot/enclave.nix
COPY .enclavehub.yml /usr/src/sgxiot/
COPY nix.Dockerfile /usr/src/sgxiot/

COPY Sensor_Data /usr/src/sgxiot/

COPY --from=build-enclave /usr/src/result/bin/enclave.signed.so enclave/enclave.signed.so
COPY --from=build-app /usr/src/sgxiot/app /usr/src/sgxiot/app

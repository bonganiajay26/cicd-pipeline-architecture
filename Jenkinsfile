pipeline {
    agent any

    environment {
        DOCKER_REGISTRY   = 'localhost:5000'
        APP_NAME          = 'python-devops-app'
        IMAGE_TAG         = "${BUILD_NUMBER}"
        IMAGE_FULL        = "${DOCKER_REGISTRY}/${APP_NAME}:${IMAGE_TAG}"
        SONAR_HOST_URL    = 'http://sonarqube:9000'
        SONAR_PROJECT_KEY = 'python-devops-app'
        KUBECONFIG        = credentials('kubeconfig')
        DOCKER_CREDS      = credentials('docker-registry-creds')
        SONAR_TOKEN       = credentials('sonar-token')
        SLACK_CHANNEL     = '#ci-cd-alerts'
        K8S_NAMESPACE     = 'cicd'
    }

    options {
        buildDiscarder(logRotator(numToKeepStr: '10'))
        timeout(time: 45, unit: 'MINUTES')
        timestamps()
        disableConcurrentBuilds()
    }

    stages {
        stage('Checkout') {
            steps {
                echo "Checking out source code from branch: ${env.BRANCH_NAME}"
                checkout scm
                script {
                    env.GIT_COMMIT_SHORT = sh(
                        script: "git rev-parse --short HEAD",
                        returnStdout: true
                    ).trim()
                    env.GIT_AUTHOR = sh(
                        script: "git log -1 --pretty=format:'%an'",
                        returnStdout: true
                    ).trim()
                    echo "Commit: ${env.GIT_COMMIT_SHORT} by ${env.GIT_AUTHOR}"
                }
            }
        }

        stage('Install Dependencies') {
            steps {
                echo "Installing Python dependencies..."
                sh '''
                    python3 -m venv venv
                    . venv/bin/activate
                    pip install --upgrade pip
                    pip install -r requirements.txt
                    pip install pytest pytest-cov flake8 bandit safety
                '''
            }
        }

        stage('Unit Tests') {
            steps {
                echo "Running unit tests with coverage..."
                sh '''
                    . venv/bin/activate
                    pytest tests/ \
                        --junitxml=reports/junit.xml \
                        --cov=app \
                        --cov-report=xml:reports/coverage.xml \
                        --cov-report=html:reports/htmlcov \
                        --cov-fail-under=80 \
                        -v
                '''
            }
            post {
                always {
                    publishCoverage adapters: [coberturaAdapter('reports/coverage.xml')],
                                   sourceFileResolver: sourceFiles('STORE_LAST_BUILD')
                }
            }
        }

        stage('Code Quality') {
            parallel {
                stage('SonarQube Analysis') {
                    steps {
                        echo "Running SonarQube static analysis..."
                        withSonarQubeEnv('SonarQube') {
                            sh """
                                sonar-scanner \
                                    -Dsonar.projectKey=${SONAR_PROJECT_KEY} \
                                    -Dsonar.projectName="${APP_NAME}" \
                                    -Dsonar.projectVersion=${IMAGE_TAG} \
                                    -Dsonar.sources=app \
                                    -Dsonar.tests=tests \
                                    -Dsonar.python.coverage.reportPaths=reports/coverage.xml \
                                    -Dsonar.python.xunit.reportPath=reports/junit.xml \
                                    -Dsonar.host.url=${SONAR_HOST_URL} \
                                    -Dsonar.token=${SONAR_TOKEN}
                            """
                        }
                        timeout(time: 10, unit: 'MINUTES') {
                            waitForQualityGate abortPipeline: true
                        }
                    }
                }

                stage('Lint & Security Scan') {
                    steps {
                        echo "Running linting and security checks..."
                        sh '''
                            . venv/bin/activate
                            flake8 app/ --max-line-length=120 --format=pylint > reports/flake8.txt || true
                            bandit -r app/ -f json -o reports/bandit.json || true
                            safety check --json > reports/safety.json || true
                        '''
                    }
                }
            }
        }

        stage('Build Docker Image') {
            steps {
                echo "Building Docker image: ${IMAGE_FULL}"
                sh """
                    docker build \
                        --build-arg BUILD_NUMBER=${BUILD_NUMBER} \
                        --build-arg GIT_COMMIT=${GIT_COMMIT_SHORT} \
                        --label "build.number=${BUILD_NUMBER}" \
                        --label "git.commit=${GIT_COMMIT_SHORT}" \
                        --label "app.name=${APP_NAME}" \
                        -t ${IMAGE_FULL} \
                        -t ${DOCKER_REGISTRY}/${APP_NAME}:latest \
                        .
                """
                echo "Docker image built successfully: ${IMAGE_FULL}"
            }
        }

        stage('Trivy Scan') {
            steps {
                echo "Scanning Docker image for vulnerabilities with Trivy..."
                sh """
                    trivy image \
                        --exit-code 0 \
                        --severity HIGH,CRITICAL \
                        --format template \
                        --template "@/usr/local/share/trivy/templates/junit.tpl" \
                        --output reports/trivy-junit.xml \
                        ${IMAGE_FULL}

                    trivy image \
                        --exit-code 1 \
                        --severity CRITICAL \
                        --ignore-unfixed \
                        ${IMAGE_FULL}
                """
            }
            post {
                always {
                    junit allowEmptyResults: true, testResults: 'reports/trivy-junit.xml'
                }
            }
        }

        stage('Push to Registry') {
            steps {
                echo "Pushing image to registry: ${IMAGE_FULL}"
                sh """
                    echo ${DOCKER_CREDS_PSW} | docker login ${DOCKER_REGISTRY} \
                        -u ${DOCKER_CREDS_USR} \
                        --password-stdin
                    docker push ${IMAGE_FULL}
                    docker push ${DOCKER_REGISTRY}/${APP_NAME}:latest
                    docker logout ${DOCKER_REGISTRY}
                """
                echo "Image pushed successfully to ${IMAGE_FULL}"
            }
        }

        stage('Deploy to K8s') {
            when {
                anyOf {
                    branch 'main'
                    branch 'master'
                    branch 'release/*'
                }
            }
            steps {
                echo "Deploying to Kubernetes namespace: ${K8S_NAMESPACE}"
                sh """
                    export KUBECONFIG=${KUBECONFIG}

                    # Update image tag in deployment manifest
                    sed -i 's|IMAGE_PLACEHOLDER|${IMAGE_FULL}|g' k8s/deployment.yaml

                    # Apply namespace first
                    kubectl apply -f k8s/namespace.yaml

                    # Apply all manifests
                    kubectl apply -f k8s/deployment.yaml
                    kubectl apply -f k8s/service.yaml

                    # Wait for rollout to complete
                    kubectl rollout status deployment/${APP_NAME} \
                        -n ${K8S_NAMESPACE} \
                        --timeout=300s

                    # Verify deployment
                    kubectl get pods -n ${K8S_NAMESPACE} -l app=${APP_NAME}
                    kubectl get svc -n ${K8S_NAMESPACE}
                """
                echo "Deployment to Kubernetes completed successfully!"
            }
        }
    }

    post {
        always {
            echo "Pipeline completed. Collecting test results..."
            junit allowEmptyResults: true,
                  testResults: 'reports/junit.xml'

            archiveArtifacts artifacts: 'reports/**/*',
                             allowEmptyArchive: true,
                             fingerprint: true

            // Clean up dangling Docker images
            sh "docker image prune -f || true"

            // Clean workspace
            cleanWs(
                cleanWhenAborted: true,
                cleanWhenFailure: false,
                cleanWhenSuccess: true,
                deleteDirs: true
            )
        }

        success {
            echo "Pipeline succeeded! Sending success notification..."
            slackSend(
                channel: "${SLACK_CHANNEL}",
                color: 'good',
                message: """
*BUILD SUCCEEDED* :white_check_mark:
*Job:* ${JOB_NAME}
*Build:* #${BUILD_NUMBER}
*Branch:* ${BRANCH_NAME}
*Commit:* ${GIT_COMMIT_SHORT} by ${GIT_AUTHOR}
*Image:* `${IMAGE_FULL}`
*Duration:* ${currentBuild.durationString}
*Details:* ${BUILD_URL}
                """.stripIndent().trim()
            )
        }

        failure {
            echo "Pipeline failed! Sending failure notification..."
            slackSend(
                channel: "${SLACK_CHANNEL}",
                color: 'danger',
                message: """
*BUILD FAILED* :x:
*Job:* ${JOB_NAME}
*Build:* #${BUILD_NUMBER}
*Branch:* ${BRANCH_NAME}
*Commit:* ${GIT_COMMIT_SHORT} by ${GIT_AUTHOR}
*Stage Failed:* ${env.STAGE_NAME ?: 'Unknown'}
*Duration:* ${currentBuild.durationString}
*Details:* ${BUILD_URL}
                """.stripIndent().trim()
            )
        }

        unstable {
            slackSend(
                channel: "${SLACK_CHANNEL}",
                color: 'warning',
                message: """
*BUILD UNSTABLE* :warning:
*Job:* ${JOB_NAME}
*Build:* #${BUILD_NUMBER}
*Branch:* ${BRANCH_NAME}
*Details:* ${BUILD_URL}
                """.stripIndent().trim()
            )
        }
    }
}

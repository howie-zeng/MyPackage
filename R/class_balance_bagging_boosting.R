#' @export
bbaging <-
  function(x, ...)
    UseMethod("bbaging")
#' @export
bbaging.data.frame <-
  function(x, y, numBag = 40, base = treeBag, type = "SMOTEBagging", allowParallel = FALSE, ...)
  {
    # Input:
    #         x: A data frame of predictors from the training set
    #         y: A vector of the response variable from the training set
    #    numBag: Number of bags
    #      base: Base learner (e.g., treeBag)
    #      type: Type of bagging-based algorithm ("SMOTEBagging","RUSBagging","RBBagging","ROSBagging")
    # allowParallel: If TRUE, run using parallel computing

    library(foreach)
    if (allowParallel) library(doParallel)

    funcCall <- match.call(expand.dots = FALSE)
    if (!type %in% c("RUSBagging", "ROSBagging", "SMOTEBagging", "RBBagging"))
      stop("Invalid method type for `type` argument.")

    data <- data.frame(x, y)
    tgt <- length(data)
    x.nam <- names(x)
    form <- as.formula(paste("y ~ ", paste(x.nam, collapse = "+")))
    classTable <- table(data[, tgt])
    classTable <- sort(classTable, decreasing = TRUE)
    classLabels <- names(classTable)

    CreateResample <- function(data, tgt, classLabels, type, numBag, iter, ...)
    {
      indexMaj <- which(data[, tgt] == classLabels[1])
      indexMin <- which(data[, tgt] == classLabels[2])
      numMin   <- length(indexMin)
      numMaj   <- length(indexMaj)

      if (type == "RUSBagging") {
        # RUSBagging
        indexMajSampled <- sample(indexMaj, numMin, replace = FALSE)
        indexMinSampled <- sample(indexMin, numMin, replace = TRUE)
        indexNew <- c(indexMajSampled, indexMinSampled)
        newData  <- data[indexNew, ]
      }

      if (type == "ROSBagging") {
        # ROSBagging
        indexMajSampled <- sample(indexMaj, numMaj, replace = TRUE)
        numMinsampled   <- numMaj - numMin
        indexMinSampled <- sample(indexMin, numMinsampled, replace = TRUE)
        indexNew <- c(indexMajSampled, indexMinSampled, indexMin)
        newData  <- data[indexNew, ]
      }

      if (type == "RBBagging") {
        # RBBagging
        numMajSampled   <- rnbinom(1, numMin, 0.5)
        indexMajSampled <- sample(indexMaj, numMajSampled, replace = FALSE)
        indexMinSampled <- sample(indexMin, numMin, replace = TRUE)
        indexNew <- c(indexMajSampled, indexMinSampled)
        newData  <- data[indexNew, ]
      }

      if (type == "SMOTEBagging") {
        # SMOTEBagging
        numCol <- dim(data)[2]
        n <- (iter - 1) %/% (numBag / 10) + 1
        numMinSampled   <- round(numMaj * n / 10)
        indexMinSampled <- sample(indexMin, numMinSampled, replace = TRUE)
        indexMajSampled <- sample(indexMaj, numMaj, replace = TRUE)
        indexNew <- c(indexMajSampled, indexMinSampled)
        dataROS  <- data[indexNew, ]
        perOver  <- round((numMaj - numMinSampled) / numMin) * 100

        if (perOver > 0) {
          if (tgt < numCol) {
            cols <- 1:numCol
            cols[c(tgt, numCol)] <- cols[c(numCol, tgt)]
            data <- data[, cols]
          }
          newExs <- SmoteExs(data[indexMin, ], perOver, k = 5)
          if (tgt < numCol) {
            newExs <- newExs[, cols]
            data   <- data[, cols]
          }
          newData <- rbind(dataROS, newExs)
        } else {
          newData <- dataROS
        }
      }
      return(newData)
    }

    fitter <- function(form, data, tgt, classLabels, type, base, numBag, iter, ...)
    {
      dataSampled <- CreateResample(data, tgt, classLabels, type, numBag, iter, ...)
      model <- base$fit(form, dataSampled)
    }

    if (allowParallel) {
      `%op%` <- `%dopar%`
      cl <- makeCluster(detectCores()/2)
      registerDoParallel(cl)
    } else {
      `%op%` <- `%do%`
    }

    btFits <- foreach(iter = seq_len(numBag),
                      .verbose = FALSE,
                      .errorhandling = "stop") %op% fitter(form, data, tgt, classLabels, type, base, numBag, iter, ...)

    if (allowParallel) stopCluster(cl)

    structure(
      list(call         = funcCall,
           base         = base,
           type         = type,
           numBag       = numBag,
           classLabels  = classLabels,
           fits         = btFits),
      class = "bbag"
    )
  }

#' @export
predict.bbag <-
  function(obj, x, type = "class")
  {
    if (is.null(x)) stop("Please provide predictors for prediction")
    data <- x
    btPred <- sapply(obj$fits, obj$base$pred, data = data)
    obj$base$aggregate(btPred, obj$classLabels, type)
  }

treeBag <- list(
  fit = function(form, data) {
    library(rpart)
    out <- rpart(form, data)
    return(out)
  },

  pred = function(object, data) {
    out <- predict(object, data, type = "class")
  },

  aggregate = function(x, classLabels, type) {
    if (!type %in% c("class", "probability"))
      stop("Invalid `type` argument.")
    numClass <- length(classLabels)
    numIns   <- nrow(x)
    numBag   <- ncol(x)
    classfinal <- matrix(0, ncol = numClass, nrow = numIns)
    colnames(classfinal) <- classLabels

    for (i in seq_len(numClass)) {
      classfinal[, i] <- (x == classLabels[i]) %*% rep(1, numBag)
    }

    if (type == "class") {
      out <- factor(classLabels[apply(classfinal, 1, which.max)], levels = classLabels)
    } else {
      out <- as.data.frame(classfinal / numBag)
    }
    out
  }
)


#' @export
bboost <-
  function(x, ...)
    UseMethod("bboost")
#' @export
bboost.data.frame <-
  function(x, y, iter = 40, base =  treeBoost, type = "SMOTEBoost", costRatio = 56/11, ...)
  {
    # Input:
    #       x: A data frame of the predictors from training data
    #       y: A vector of response variable from training data
    #    iter: Number of training iterations
    #    base: Base learner
    #    type: Type of boosting-based algorithm, including "Adaboost", "SMOTEboost","RUSBoost", "AdaC2"


    if (!type %in% c("AdaBoost", "SMOTEBoost","RUSBoost", "AdaC2"))
      stop("type must be AdaBoost, SMOTEBOost, RUSBoost or AdaC2")
    funcCall <- match.call(expand.dots = FALSE)


    # find the majority and minority class
    data <- data.frame(x, y)
    tgt <- length(data)
    classTable  <- table(data[, tgt])
    classTable  <- sort(classTable, decreasing = TRUE)
    classLabels <- names(classTable)
    indexMaj <- which(data[, tgt] == classLabels[1])
    indexMin <- which(data[, tgt] == classLabels[2])
    numMin <- length(indexMin)
    numMaj <- length(indexMaj)
    numRow <- dim(data)[1]

    #initialization
    x.nam <- names(x)
    form <- as.formula(paste("y ~ ", paste(x.nam, collapse = "+")))
    H      <- list()
    alpha  <- rep(0, iter)
    oldWeight <- rep(1/numRow, numRow)
    newWeight <- rep(NA, numRow)
    count <- 0
    t <- 0
    earlyStop <- FALSE

    if (type == "AdaC2")
    {
      cost <- rep(1, numRow)
      cost[indexMin] <- costRatio
    }

    while (t < iter) {
      t <- t + 1
      #data preparation
      if (type == "AdaBoost" | type == "AdaC2"){
        indexBootstrap <- sample(1:numRow, replace = TRUE, prob = oldWeight)
        dataResample   <- data[indexBootstrap, ]
      }

      if (type == "SMOTEBoost") {
        perOver  <- ((numMaj - numMin)/numMin)*100
        dataSmoteSample  <- SMOTE_1(form, data, perOver)
        numNew <- dim(dataSmoteSample)[1]
        resampleWeight <- rep(NA, numNew)
        resampleWeight[1:numRow] <- oldWeight
        resampleWeight[(numRow+1):numNew] <- 1/numNew
        indexBootstrap <- sample(1:numNew, replace = TRUE, prob = resampleWeight)
        dataResample   <- dataSmoteSample[indexBootstrap, ]
      }

      if (type == "RUSBoost") {
        indexMajRUS <- sample(1:numMaj, numMin)
        indexNew    <- c(indexMaj[indexMajRUS], indexMin)
        resampleWeight <- oldWeight[indexNew]
        indexBootstrap <- sample(1:(2*numMin), replace = TRUE, prob = resampleWeight)
        dataResample <- data[indexNew[indexBootstrap], ]
      }

      # build classifier with resampling
      H[[t]] <- base$fit(form, dataResample)

      # Computing the (pseudo) loss of hypothesis
      if (type == "AdaBoost")
      {
        weakPrediction <- base$pred(H[[t]], data, type = "class")
        ind  <- data[, tgt]== weakPrediction
        loss <- sum(oldWeight * as.numeric(!ind))
        beta <- loss/(1-loss)
        alpha[t] <- log(1/beta)
      }

      if (type == "RUSBoost" | type == "SMOTEBoost")
      {
        weakPrediction <- base$pred(H[[t]], data, type = "prob")
        loss <- sum(oldWeight * abs(weakPrediction[, 2] - as.numeric(data[, tgt]) + 1))
        beta <- loss/(1-loss)
        alpha[t]  <- log(1/beta)
      }

      if (type == "AdaC2")
      {
        weakPrediction <- base$pred(H[[t]], data, type = "class")
        ind  <- data[, tgt]== weakPrediction
        alpha[t]<- 0.5*log(sum(oldWeight[ind]* cost[ind])/sum(oldWeight[!ind]*cost[!ind]))
      }

      if ( alpha[t] < 0){
        count <- count + 1
        t <- t - 1
        if (count > 5){
          earlyStop <- TRUE
          warning("stop with too many big errors")
          break
        } else {
          next
        }
      } else {
        count <- 1
      }

      if (type == "AdaBoost")
      {
        newWeight[ind]   <- oldWeight[ind]*beta
        newWeight[!ind]  <- oldWeight[!ind ]
      }

      if (type == "RUSBoost" | type == "SMOTEBoost")
      {
        newWeight <- oldWeight*beta^(1-abs(weakPrediction[, 2] - as.numeric(data[, tgt]) + 1))
      }

      if (type == "AdaC2")
      {
        newWeight[ind]   <- oldWeight[ind]*exp(-alpha[t]) * cost[ind]
        newWeight[!ind]  <- oldWeight[!ind]*exp(alpha[t]) * cost[!ind]
      }

      newWeight <- newWeight / sum(newWeight)
      oldWeight <- newWeight
    }
    if (earlyStop) {
      iter <-  t
      alpha <- alpha[1:iter]
      H <- H[1:iter]
    }

    structure(
      list(call        = funcCall,
           type        = type,
           base        = base,
           classLabels = classLabels,
           iter        = iter,
           fits        = H   ,
           alpha       = alpha),
      class = "bboost")
  }
#' @export
predict.bboost<-
  function(obj, x, type = "class")
  {
    #  input
    #     obj: Output from bboost.formula
    #       x: A data frame of the predictors from testing data

    if(is.null(x)) stop("please provide predictors for prediction")
    data <- x
    btPred <- sapply(obj$fits, obj$base$pred, data = data)
    obj$base$aggregate(btPred, obj$alpha, obj$classLabels, type=type)
  }

treeBoost <- list(
  fit = function(form, data)
  {
    library(rpart)
    out<-rpart(form,data)
    return(out)
  },

  pred = function(object, data, type="class")
  {
    out <- predict(object, data,  type=type)
  },

  aggregate = function(x, weight, classLabels, type = "class")
  {
    if (!type %in% c("class", "probability"))
      stop("wrong setting with type")
    numClass   <- length(classLabels)
    numIns     <- dim(x)[1]
    iter       <- dim(x)[2]
    classfinal <- matrix(0, ncol = numClass, nrow = numIns)
    colnames(classfinal) <- classLabels
    for (i in 1:numClass){
      classfinal[,i] <- matrix(as.numeric(x == classLabels[i]), nrow = numIns)%*%weight
    }
    if(type == "class")
    {
      out <- factor(classLabels[apply(classfinal, 1, which.max)], levels = classLabels )
    } else {
      out <-  classfinal/rowSums(classfinal)
    }
    out
  })

#' @export
BalanceCascade <-
  function(x, ...)
    UseMethod("BalanceCascade")
#' @export
BalanceCascade.data.frame <-
  function(x, y, iter = 4)
  {
    # Input:
    #        x: A data frame of predictors from the training set
    #        y: A vector of the response variable from the training set
    #     iter: Number of iterations to train base classifiers

    funcCall <- match.call(expand.dots = FALSE)
    data <- data.frame(x, y)
    tgt <- length(data)
    classTable  <- table(data[, tgt])
    classTable  <- sort(classTable, decreasing = TRUE)
    classLabels <- names(classTable)
    indexMaj <- which(data[, tgt] == classLabels[1])
    indexMin <- which(data[, tgt] == classLabels[2])
    numMin <- length(indexMin)
    numMaj <- length(indexMaj)
    FP <- (numMin / numMaj)^(1/(iter-1))

    x.nam <- names(x)
    form <- as.formula(paste("y ~ ", paste(x.nam, collapse = "+")))
    H <- list()
    thresh <- rep(NA, iter)

    for (i in seq_len(iter)) {
      if (length(indexMaj) < numMin)
        numMin  <- length(indexMaj)
      indexMajSampling <- sample(indexMaj, numMin)
      dataCurrent <- data[c(indexMin, indexMajSampling), ]
      H[[i]] <- bboost.data.frame(dataCurrent[, -tgt], dataCurrent[, tgt], type = "AdaBoost")
      pred   <- predict(H[[i]], data[indexMaj, -tgt], type = "probability")
      sortIndex <- order(pred[, 2], decreasing = TRUE)
      numkeep   <- round(length(indexMaj) * FP)
      thresh[i] <- pred[sortIndex[numkeep], 2] * sum(H[[i]]$alpha)
      indexMaj  <- indexMaj[sortIndex[1:numkeep]]
    }

    iter   <- sum(sapply(H, "[[", 5))
    fits   <- unlist(lapply(H, "[[", 6), recursive = FALSE)
    alphas <- unlist(lapply(H, "[[", 7))

    structure(
      list(call        = funcCall,
           iter        = iter,
           classLabels = classLabels,
           base        = H[[1]]$base,
           alphas      = alphas,
           fits        = fits,
           thresh      = sum(thresh)),
      class = "BalanceCascade"
    )
  }
#' @export
predict.BalanceCascade <-
  function(obj, x, type = "class")
  {
    if (is.null(x)) stop("Please provide predictors for prediction")
    if (!type %in% c("class", "probability"))
      stop("Invalid `type` argument.")

    data <- x
    classLabels <- obj$classLabels
    numClass    <- length(classLabels)
    numIns      <- nrow(data)
    weight      <- obj$alphas
    btPred      <- sapply(obj$fits, obj$base$pred, data = data, type ="class")
    classfinal  <- matrix(0, ncol = numClass, nrow = numIns)
    colnames(classfinal) <- classLabels

    for (i in seq_len(numClass)) {
      classfinal[, i] <- (btPred == classLabels[i]) %*% weight
    }

    if (type == "class") {
      classfinal <- classfinal - obj$thresh
      out <- factor(classLabels[apply(classfinal, 1, which.max)], levels = classLabels)
    } else {
      out <- data.frame(classfinal / rowSums(classfinal))
    }
    out
  }


#' @export
EasyEnsemble <-
  function(x, ...)
    UseMethod("EasyEnsemble")
#' @export
EasyEnsemble.data.frame <-
  function(x, y, iter = 4, allowParallel = FALSE, ...)
  {
    # Input:
    #       x: A data frame of predictors from the training set
    #       y: A vector of the response variable from the training set
    #    iter: Iterations to train base classifiers
    # allowParallel: If TRUE, run using parallel computing

    library(foreach)
    if (allowParallel) library(doParallel)

    funcCall <- match.call(expand.dots = FALSE)
    data <- data.frame(x, y)
    tgt <- length(data)
    classTable <- table(data[, tgt])
    classTable <- sort(classTable, decreasing = TRUE)
    classLabels <- names(classTable)
    indexMaj <- which(data[, tgt] == classLabels[1])
    indexMin <- which(data[, tgt] == classLabels[2])
    numMin <- length(indexMin)
    numMaj <- length(indexMaj)
    H <- list()

    fitter <- function(tgt, data, indexMaj, numMin, indexMin) {
      indexMajCurrent <- sample(indexMaj, numMin)
      dataCurrent <- data[c(indexMin, indexMajCurrent),]
      out <- bboost.data.frame(dataCurrent[, -tgt], dataCurrent[, tgt], type = "AdaBoost")
    }

    if (allowParallel) {
      `%op%` <- `%dopar%`
      cl <- makeCluster(2)
      registerDoParallel(cl)
    } else {
      `%op%` <- `%do%`
    }

    H  <- foreach(i = seq_len(iter),
                  .verbose = FALSE,
                  .errorhandling = "stop") %op% fitter(tgt, data, indexMaj, numMin, indexMin)

    if (allowParallel) stopCluster(cl)

    iter   <- sum(sapply(H, "[[", 5))
    fits   <- unlist(lapply(H, "[[", 6), recursive = FALSE)
    alphas <- unlist(lapply(H, "[[", 7))

    structure(
      list(call        = funcCall,
           iter        = iter,
           fits        = fits,
           base        = H[[1]]$base,
           alphas      = alphas,
           classLabels = classLabels),
      class = "EasyEnsemble"
    )
  }

#' @export
predict.EasyEnsemble <-
  function(obj, x, type = "class")
  {
    if (is.null(x)) stop("Please provide predictors for prediction")
    if (!type %in% c("class", "probability"))
      stop("Invalid `type` argument.")
    data <- x
    classLabels <- obj$classLabels
    numClass    <- length(classLabels)
    numIns      <- nrow(data)
    weight      <- obj$alphas
    btPred      <- sapply(obj$fits, obj$base$pred, data = data, type ="class")
    classfinal  <- matrix(0, ncol = numClass, nrow = numIns)
    colnames(classfinal) <- classLabels

    for (i in seq_len(numClass)) {
      classfinal[, i] <- (btPred == classLabels[i]) %*% weight
    }

    if (type == "class") {
      out <- factor(classLabels[apply(classfinal, 1, which.max)], levels = classLabels)
    } else {
      out <- data.frame(classfinal / rowSums(classfinal))
    }
    out
  }


#' @export
SMOTETomek <-
  function(x, y, percOver = 1400, k = 5)
  {
    # Inputs
    #      x    : A data frame of predictors from the training set
    #      y    : A vector of response variable from the training set
    #   perOver : Number of new instances generated for each minority instance (in SMOTE)
    #   k       : Number of nearest neighbors in SMOTE

    newData <- SMOTE(x, y, percOver, k)
    tgt <- length(newData)
    indexTL <- TomekLink(tgt, newData)
    newDataRemoved <- newData[!indexTL, ]
    return(newDataRemoved)
  }
#' @export
TomekLink <-
    function(tgt, data)
        # Inputs:
        #   form: model formula
        #   data: dataset
        # Output:
        #   logical vector indicating whether a instance is in TomekLinks
    {

        indexTomek <- rep(FALSE, nrow(data))

        # find the column of class variable
        classTable <- table(data[, tgt])

        # seperate the group
        majCl <- names(which.max(classTable))
        minCl <- names(which.min(classTable))

        # get the instances of the larger group
        indexMin <- which(data[, tgt] == minCl)
        #numMin  <- length(indexMin)


        # convert dataset in numeric matrix
        dataTransformed <- Numeralize(data[, -tgt])

        # generate indicator matrix
        require("RANN")
        indexOrder1  <- nn2(dataTransformed, dataTransformed[indexMin, ], k = 2)$nn.idx
        indexTomekCa <- data[indexOrder1[, 2], tgt] == majCl
        if (sum(indexTomekCa) > 0)
        {
            TomekCa <- cbind(indexMin[indexTomekCa],indexOrder1[indexTomekCa, 2])

            # find nearest neighbour of potential majority instance
            indexOrder2 <- nn2(dataTransformed, dataTransformed[TomekCa[, 2], ], k = 2)$nn.idx
            indexPaired <- indexOrder2[ ,2] == TomekCa[, 1]
            if (sum(indexPaired) > 0)
            {
                indexTomek[TomekCa[indexPaired, 1]] <- TRUE
                indexTomek[TomekCa[indexPaired, 2]] <- TRUE
            }
        }
        return(indexTomek)
    }
#' @export
SMOTE <-
  function(x, y, percOver = 1400, k = 5)
  {
    # SMOTE sampling
    # Inputs:
    #    x: Predictors (data frame)
    #    y: Response variable (factor)
    #    percOver/100: Number of new instances generated for each minority instance
    #    k: Number of nearest neighbors

    data <- data.frame(x, y)
    classTable <- table(y)
    tgt <- length(data)
    minClass <- names(which.min(classTable))
    indexMin <- which(data[, tgt] == minClass)
    numMin <- length(indexMin)
    majClass <- names(which.max(classTable))
    indexMaj <- which(data[, tgt] == majClass)

    if (percOver < 100) {
      indexMinSelect <- sample(seq_len(numMin), round(numMin * percOver / 100))
      dataMinSelect  <- data[indexMin[indexMinSelect], ]
      percOver <- 100
    } else {
      dataMinSelect <- data[indexMin, ]
    }

    newExs <- SmoteExs(dataMinSelect, percOver, k)
    newData <- rbind(data, newExs)
    return(newData)
  }
#' @export
Numeralize <-
  function(data, form = NULL)
  {
    if (!is.null(form))
    {
      tgt    <- which(names(data) == as.character(form[[2]]))
      dataY <- data[drop = FALSE,, tgt]
      dataX <- data[, -tgt]
    } else {
      dataX <- data
    }
    numRow      <- dim(dataX)[1]
    #numCol      <- dim(dataX)[2]
    indexOrder      <- sapply(dataX, is.ordered)
    indexMultiValue <- sapply(dataX, nlevels)>2
    indexNominal    <- !indexOrder & indexMultiValue
    numerMatrixNames<- NULL
    if (all(indexNominal))
    {
      numerMatrix   <- NULL
    } else {
      numerMatrix      <- dataX[drop = FALSE, ,!indexNominal]
      numerMatrixNames <- colnames(numerMatrix)
      numerMatrix      <- data.matrix(numerMatrix)
      Min              <- apply(numerMatrix, 2, min)
      range            <- apply(numerMatrix, 2, max)-Min
      numerMatrix      <- scale(numerMatrix, Min, range)[, ]
    }

    if (any(indexNominal))
    {

      BiNames     <- NULL
      dataNominal <- dataX[drop = FALSE, ,indexNominal]
      numNominal  <- sum(indexNominal)
      if (numNominal>1)
      {
        dimEx <- sum(sapply(dataX[,indexNominal], nlevels))
      } else {
        dimEx <- nlevels(dataX[, indexNominal])
      }
      dataBinary  <- matrix(nrow = numRow, ncol = dimEx )
      cl <- 0
      for (i in 1:numNominal)
      {
        numCat <- nlevels(dataNominal[, i])
        for (j in 1:numCat)
        {
          value <- levels(dataNominal[, i])[j]
          ind  <- (dataNominal[,i] == value)
          dataBinary[, cl+1] <- as.integer(ind)
          BiNames[cl+1]   <- paste(names(dataNominal)[i], "_", value, sep="")
          cl <- cl+1
        }
      }
      numerMatrix  <- cbind(numerMatrix, dataBinary)
      colnames(numerMatrix) <- c(numerMatrixNames, BiNames)
    }

    if (!is.null(form))
    {
      numerMatrix <- data.frame(numerMatrix)
      numerMatrix <- cbind(numerMatrix, dataY)
    }
    return(numerMatrix)
  }
SMOTE_1 <-
  function(form, data, perOver = 500, k = 5)
    # INPUTS:
    #    form: model formula
    #    data: original  dataset
    #    perOver/100: number of new instance generated for each minority instance
    #    k: number of nearest  neighbours
  {

    # find the class variable
    tgt <- which(names(data) == as.character(form[[2]]))
    classTable<- table(data[, tgt])
    numCol <- dim(data)[2]

    # find the minority and majority instances
    minClass  <- names(which.min(classTable))
    indexMin  <- which(data[, tgt] == minClass)
    numMin    <- length(indexMin)
    majClass  <- names(which.max(classTable))
    indexMaj  <- which(data[, tgt] == majClass)
    numMaj    <- length(indexMaj)

    # move the class variable to the last column

    if (tgt < numCol)
    {
      cols <- 1:numCol
      cols[c(tgt, numCol)] <- cols[c(numCol, tgt)]
      data <- data[, cols]
    }
    # generate synthetic minority instances
    if (perOver < 100)
    {
      indexMinSelect <- sample(1:numMin, round(numMin*perOver/100))
      dataMinSelect  <- data[indexMin[indexMinSelect], ]
      perOver <- 100
    } else {
      dataMinSelect <- data[indexMin, ]
    }

    newExs <- SmoteExs(dataMinSelect, perOver, k)

    # move the class variable back to original position
    if (tgt < numCol)
    {
      newExs <- newExs[, cols]
      data   <- data[, cols]
    }

    # unsample for the majority intances
    newData <- rbind(data, newExs)

    return(newData)
  }

#' @export
SmoteExs<-
  function(data, percOver, k)
    # Input:
    #     data      : dataset of the minority instances
    #     percOver   : percentage of oversampling
    #     k         : number of nearest neighours

  {
    # transform factors into integer
    nomAtt  <- c()
    numRow  <- dim(data)[1]
    numCol  <- dim(data)[2]
    dataX   <- data[ ,-numCol]
    dataTransformed <- matrix(nrow = numRow, ncol = numCol-1)
    for (col in 1:(numCol-1))
    {
      if (is.factor(data[, col]))
      {
        dataTransformed[, col] <- as.integer(data[, col])
        nomAtt <- c(nomAtt , col)
      } else {
        dataTransformed[, col] <- data[, col]
      }
    }
    numExs  <-  round(percOver/100) # this is the number of artificial instances generated
    newExs  <-  matrix(ncol = numCol-1, nrow = numRow*numExs)

    indexDiff <- sapply(dataX, function(x) length(unique(x)) > 1)
    numerMatrix <- Numeralize(dataX[ ,indexDiff])
    require("RANN")
    id_order <- nn2(numerMatrix, numerMatrix, k+1)$nn.idx
    for(i in 1:numRow)
    {
      kNNs   <- id_order[i, 2:(k+1)]
      newIns <- InsExs(dataTransformed[i, ], dataTransformed[kNNs, ], numExs, nomAtt)
      newExs[((i-1)*numExs+1):(i*numExs), ] <- newIns
    }

    # get factors as in the original data.
    newExs <- data.frame(newExs)
    for(i in nomAtt)
    {
      newExs[, i] <- factor(newExs[, i], levels = 1:nlevels(data[, i]), labels = levels(data[, i]))
    }
    newExs[, numCol] <- factor(rep(data[1, numCol], nrow(newExs)), levels=levels(data[, numCol]))
    colnames(newExs) <- colnames(data)
    return(newExs)
  }

#=================================================================
# InsExs: generate Synthetic instances from nearest neighborhood
#=================================================================
#' @export
InsExs <-
  function(instance, dataknns, numExs, nomAtt)
    # Input:
    #    instance : selected instance
    #    dataknns : nearest instance set
    #    numExs   : number of new intances generated for each instance
    #    nomAtt   : indicators of factor variables
  {
    numRow  <- dim(dataknns)[1]
    numCol  <- dim(dataknns)[2]
    newIns <- matrix (nrow = numExs, ncol = numCol)
    neig   <- sample(1:numRow, size = numExs, replace = TRUE)

    # generated  attribute values
    insRep  <- matrix(rep(instance, numExs), nrow = numExs, byrow = TRUE)
    diffs   <- dataknns[neig,] - insRep
    newIns  <- insRep + runif(1)*diffs
    # randomly change nominal attribute
    for (j in nomAtt)
    {
      newIns[, j]   <- dataknns[neig, j]
      indexChange   <- runif(numExs) < 0.5
      newIns[indexChange, j] <- insRep[indexChange, j]
    }
    return(newIns)
  }

#' @export
EasyEnsemble <-
  function(x, ...)
    UseMethod("EasyEnsemble")

EasyEnsemble.data.frame <-
  function(x, y, iter = 4, allowParallel = FALSE, ...)
  {
    # Input:
    #       x: A data frame of the predictors from training data
    #       y: A vector of response variable from training data
    #    iter: Iterations to train base classifiers
    # allowParallel: A logical number to control the parallel computing. If allowParallel =TRUE, the function is run using parallel techniques


    library(foreach)
    if (allowParallel) library(doParallel)

    funcCall <- match.call(expand.dots = FALSE)
    data <- data.frame(x, y)
    tgt <- length(data)
    #tgt <- which(names(data) == as.character(form[[2]]))
    classTable   <- table(data[, tgt])
    classTable   <- sort(classTable, decreasing = TRUE)
    classLabels  <- names(classTable)
    indexMaj <- which(data[, tgt] == classLabels[1])
    indexMin <- which(data[, tgt] == classLabels[2])
    numMin <- length(indexMin)
    numMaj <- length(indexMaj)

    #x.nam <- names(x)
    #form <- as.formula(paste("y~ ", paste(x.nam, collapse = "+")))
    H      <- list()

    fitter <- function(tgt, data, indexMaj, numMin, indexMin)
    {
      indexMajCurrent <- sample(indexMaj, numMin)
      dataCurrent <- data[c(indexMin, indexMajCurrent),]
      out <- bboost.data.frame(dataCurrent[, -tgt], dataCurrent[,tgt], type = "AdaBoost")
    }
    if (allowParallel) {
      `%op%` <- `%dopar%`
      cl <- makeCluster(2)
      registerDoParallel(cl)
    } else {
      `%op%` <- `%do%`
    }
    H  <- foreach(i = seq(1:iter),
                  .verbose = FALSE,
                  .errorhandling = "stop") %op% fitter(tgt, data , indexMaj, numMin, indexMin)

    if (allowParallel) stopCluster(cl)

    iter   <- sum(sapply(H,"[[", 5))
    fits   <- unlist(lapply(H,"[[", 6), recursive = FALSE)
    alphas <- unlist(lapply(H,"[[", 7))
    structure(
      list(call       = funcCall    ,
           iter       = iter        ,
           fits       = fits        ,
           base       = H[[1]]$base ,
           alphas     = alphas      ,
           classLabels = classLabels),
      class = "EasyEnsemble")
  }


predict.EasyEnsemble <-
  function(obj, x, type = "class")
  {

    #  input
    #     obj: Output from bboost.formula
    #       x: A data frame of the predictors from testing data

    if(is.null(x)) stop("please provide predictors for prediction")
    if (!type %in% c("class", "probability"))
      stop("wrong setting with type")
    data <- x
    classLabels <- obj$classLabels
    numClass    <- length(classLabels)
    numIns      <- dim(data)[1]
    weight      <- obj$alphas
    btPred      <- sapply(obj$fits, obj$base$pred, data = data, type ="class")
    classfinal  <- matrix(0, ncol = numClass, nrow = numIns)
    colnames(classfinal) <- classLabels
    for (i in 1:numClass){
      classfinal[, i] <- matrix(as.numeric(btPred == classLabels[i]), nrow = numIns)%*%weight
    }
    if (type == "class")
    {
      out <- factor(classLabels[apply(classfinal, 1, which.max)], levels = classLabels)
    } else {
      out <- data.frame(classfinal/rowSums(classfinal))
    }
    out

  }
#=========================================================
# SmoteExs: Generate SMOTE instances for minority class
#=========================================================

#' Generate synthetic SMOTE instances for a minority class
#'
#' @param data A data frame containing the minority class instances
#' @param percOver Percentage of oversampling (e.g., 200 for 200%)
#' @param k Number of nearest neighbors to consider
#'
#' @return A data frame containing synthetic instances for the minority class
#'
#' @importFrom RANN nn2
#' @export
SmoteExs <- function(data, percOver, k) {
  # Input:
  #   data     : Dataset containing minority class instances
  #   percOver : Percentage of oversampling (e.g., 200 for 200%)
  #   k        : Number of nearest neighbors

  # Initialize variables
  nomAtt <- c()  # Indices of nominal (factor) attributes
  numRow <- nrow(data)  # Number of rows in the data
  numCol <- ncol(data)  # Number of columns in the data
  dataX <- data[, -numCol]  # Exclude the target column for processing
  dataTransformed <- matrix(nrow = numRow, ncol = numCol - 1)

  # Transform factors to integers for processing
  for (col in 1:(numCol - 1)) {
    if (is.factor(data[, col])) {
      dataTransformed[, col] <- as.integer(data[, col])
      nomAtt <- c(nomAtt, col)
    } else {
      dataTransformed[, col] <- data[, col]
    }
  }

  # Calculate the number of synthetic instances to generate
  numExs <- round(percOver / 100)
  newExs <- matrix(ncol = numCol - 1, nrow = numRow * numExs)

  # Ensure columns with unique values are processed correctly
  indexDiff <- sapply(dataX, function(x) length(unique(x)) > 1)
  require("RANN")  # Load RANN for nearest neighbor search

  # Find k nearest neighbors
  numerMatrix <- as.matrix(dataX[, indexDiff])
  nnIndices <- nn2(numerMatrix, numerMatrix, k + 1)$nn.idx

  # Generate synthetic instances for each row
  for (i in 1:numRow) {
    kNNs <- nnIndices[i, 2:(k + 1)]  # Exclude the first neighbor (itself)
    newInstances <- InsExs(dataTransformed[i, ], dataTransformed[kNNs, ], numExs, nomAtt)
    newExs[((i - 1) * numExs + 1):(i * numExs), ] <- newInstances
  }

  # Convert generated data back to original format
  newExs <- data.frame(newExs)
  for (i in nomAtt) {
    newExs[, i] <- factor(newExs[, i], levels = 1:nlevels(data[, i]), labels = levels(data[, i]))
  }

  # Assign the target column with the minority class label
  newExs[, numCol] <- factor(rep(data[1, numCol], nrow(newExs)), levels = levels(data[, numCol]))
  colnames(newExs) <- colnames(data)

  return(newExs)
}

#=================================================================
# InsExs: Generate synthetic instances using nearest neighbors
#=================================================================

#' Generate synthetic instances from nearest neighbors
#'
#' @param instance A single instance to oversample from
#' @param dataknns Nearest neighbor instances
#' @param numExs Number of synthetic instances to generate
#' @param nomAtt Indices of nominal (factor) attributes
#'
#' @return A matrix containing generated synthetic instances
#' @export
InsExs <- function(instance, dataknns, numExs, nomAtt) {
  # Input:
  #   instance  : Single instance to oversample from
  #   dataknns  : Nearest neighbor instances
  #   numExs    : Number of synthetic instances to generate
  #   nomAtt    : Indices of nominal (factor) attributes

  numRow <- nrow(dataknns)  # Number of nearest neighbors
  numCol <- ncol(dataknns)  # Number of attributes
  newIns <- matrix(nrow = numExs, ncol = numCol)

  # Randomly sample neighbors
  neighbors <- sample(1:numRow, size = numExs, replace = TRUE)

  # Generate synthetic instances
  insRep <- matrix(rep(instance, numExs), nrow = numExs, byrow = TRUE)
  diffs <- dataknns[neighbors, ] - insRep
  newIns <- insRep + runif(numExs) * diffs

  # Adjust nominal attributes
  for (j in nomAtt) {
    newIns[, j] <- dataknns[neighbors, j]
    indexChange <- runif(numExs) < 0.5
    newIns[indexChange, j] <- insRep[indexChange, j]
  }

  return(newIns)
}

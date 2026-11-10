"""Everything a modeling notebook needs, in one import:

    from cfb.ml import *

Gives you pandas/numpy/matplotlib/seaborn, the project's database helpers,
scikit-learn, TensorFlow/Keras, PyTorch, and plot_history().
"""
# --- standard library
import copy
import math
import os
from pathlib import Path
from types import SimpleNamespace

# --- data and plotting
import joblib
import numpy as np
import pandas as pd
import matplotlib.pyplot as plt
import seaborn as sns

# --- this project
from cfb.config import ROOT, SQL_ANALYSIS_DIR
from cfb.db import engine, read_query

# --- scikit-learn
from sklearn.base import clone
from sklearn.calibration import CalibrationDisplay, calibration_curve
from sklearn.compose import ColumnTransformer
from sklearn.ensemble import (
    HistGradientBoostingClassifier,
    HistGradientBoostingRegressor,
    RandomForestClassifier,
    RandomForestRegressor,
)
from sklearn.impute import SimpleImputer
from sklearn.isotonic import IsotonicRegression
from sklearn.linear_model import LinearRegression, LogisticRegression, Ridge
from sklearn.metrics import (
    ConfusionMatrixDisplay,
    accuracy_score,
    brier_score_loss,
    classification_report,
    confusion_matrix,
    f1_score,
    log_loss,
    mean_absolute_error,
    mean_squared_error,
    precision_score,
    r2_score,
    recall_score,
    roc_auc_score,
    roc_curve,
)
from sklearn.model_selection import (
    GridSearchCV,
    GroupShuffleSplit,
    PredefinedSplit,
    train_test_split,
)
from sklearn.pipeline import Pipeline, make_pipeline
from sklearn.preprocessing import (
    FunctionTransformer,
    OneHotEncoder,
    SplineTransformer,
    StandardScaler,
)

# --- TensorFlow / Keras
import tensorflow as tf
from tensorflow.keras import Sequential, regularizers
from tensorflow.keras.callbacks import EarlyStopping
from tensorflow.keras.layers import Activation, BatchNormalization, Dense, Dropout, Input
from tensorflow.keras.optimizers import Adam

# --- PyTorch
import torch
from torch import nn
from torch.utils.data import DataLoader, TensorDataset


def plot_history(history, title="Learning curves", metric="auc"):
    """Plot training vs validation loss, and a metric if it was tracked.

    history: a Keras History (from model.fit) or a plain dict of lists like
             {"loss": [...], "val_loss": [...], "auc": [...], "val_auc": [...]}
             (what a PyTorch training loop builds).
    metric:  the metric to draw under the loss ("auc", "mae", ...). Skipped if
             it isn't in the history.
    """
    h = history.history if hasattr(history, "history") else history
    epochs = np.arange(1, len(h["loss"]) + 1)
    best_epoch = int(np.argmin(h["val_loss"])) + 1
    has_metric = metric in h and f"val_{metric}" in h

    fig, axes = plt.subplots(2 if has_metric else 1, 1, figsize=(8, 7 if has_metric else 4),
                             sharex=True, squeeze=False)
    ax = axes[0, 0]
    ax.plot(epochs, h["loss"], label="Training loss")
    ax.plot(epochs, h["val_loss"], label="Validation loss")
    ax.axvline(best_epoch, linestyle=":", color="gray", label=f"Min val loss: {best_epoch}")
    ax.set_ylabel("Loss")
    ax.legend()
    ax.grid(True)

    if has_metric:
        ax = axes[1, 0]
        ax.plot(epochs, h[metric], label=f"Training {metric.upper()}")
        ax.plot(epochs, h[f"val_{metric}"], label=f"Validation {metric.upper()}")
        ax.axvline(best_epoch, linestyle=":", color="gray")
        ax.set_ylabel(metric.upper())
        ax.legend()
        ax.grid(True)

    axes[-1, 0].set_xlabel("Epoch")
    fig.suptitle(title)
    plt.tight_layout()
    plt.show()
